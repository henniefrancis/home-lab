#!/usr/bin/env bash
# check-container-rules.sh - the container rules of the lab, enforced on the RENDERED root compose project (R19, ADR-018).
#
# Usage: scripts/check-container-rules.sh [--json <compose-config.json>]
#   (default)  renders `docker compose config --format json` with dummy values (no secrets, nothing started), like the CI compose step
#   --json     checks a rendered file instead (the self-test, scripts/test-container-rules.sh, feeds it deliberately bad fixtures)
#
# Every service must:
#   1. run as a numeric uid:gid that is neither 0 nor 1000 (`user:`), unless it is in config/adr-018-register.tsv. The one other case is a
#      locally built image whose Dockerfile sets USER itself (ra-helper): the Dockerfile is checked instead;
#   2. have `cap_drop` containing ALL;
#   3. add back only the capabilities the register lists for it (none for every other service);
#   4. have `no-new-privileges:true` in security_opt, unless the register marks the service "exempt";
#   5. not be privileged.
# And every service named in the register must still exist, so the register cannot go stale.
# Exit 0 = clean, 1 = at least one violation (each printed), 2 = usage or tooling error.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

REGISTER=config/adr-018-register.tsv
# service:Dockerfile pairs whose image sets a numeric non-root USER itself.
IMAGE_USER=("ra-helper:traefik/ra-helper/Dockerfile")

command -v jq > /dev/null || {
  echo "jq is required" >&2
  exit 2
}
JSON=""
case "${1:-}" in
  --json)
    [ $# -eq 2 ] || {
      echo "usage: $0 [--json <file>]" >&2
      exit 2
    }
    JSON="$(cat "$2")"
    ;;
  '') ;;
  *)
    echo "usage: $0 [--json <file>]" >&2
    exit 2
    ;;
esac
if [ -z "$JSON" ]; then
  command -v docker > /dev/null || {
    echo "docker is required to render the project" >&2
    exit 2
  }
  d="$(mktemp -d)"
  trap 'rm -rf "$d"' EXIT
  mkdir -p "$d/secrets/tailscale"
  : > "$d/secrets/tailscale/tailscale.env"
  JSON="$(
    APPS_ROOT="$(cd "$d" && { pwd -W 2> /dev/null || pwd; })" DOMAIN=lab.example.test ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2 \
      RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role \
      docker compose --env-file config/lab.env config --format json
  )"
fi

# The register as JSON: {service: {caps: [...], nnp: "required|exempt"}}.
reg="$(grep -vE '^(#|$)' "$REGISTER" | tr -d '\r' | jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t")) |
  map({key: .[0], value: {caps: (if .[1] == "-" then [] else (.[1] | split(",")) end), nnp: .[2]}}) | from_entries')"
imgusers="$(printf '%s\n' "${IMAGE_USER[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0) | split(":")) | map({key: .[0], value: .[1]}) | from_entries')"

out="$(jq -r --argjson reg "$reg" --argjson iu "$imgusers" '
  def okid: test("^[0-9]+$") and (tonumber != 0) and (tonumber != 1000);
  (.services // {}) as $svc |
  ( $svc | to_entries[] | . as $e | $e.key as $n | $e.value as $v | ($reg[$n]) as $r |
    ( if $r == null and ($iu[$n] == null) then
        ( ($v.user // "") | tostring | split(":") ) as $u |
        if (($u | length) == 2 and ($u | all(okid))) then empty
        else "\($n): user must be numeric uid:gid, never 0 or 1000 (got \"\($v.user // "unset")\"); only ADR-018 register services may differ"
        end
      else empty end ),
    ( if (($v.cap_drop // []) | index("ALL")) == null then "\($n): cap_drop must contain ALL" else empty end ),
    ( (($v.cap_add // []) - (($r.caps) // [])) as $extra |
      if ($extra | length) > 0 then "\($n): cap_add \($extra | join(",")) is not allowed (register: \(($r.caps // []) | join(",") | if . == "" then "none" else . end))" else empty end ),
    ( if ($r.nnp // "required") == "required" and ((($v.security_opt // []) | index("no-new-privileges:true")) == null)
      then "\($n): security_opt must contain no-new-privileges:true" else empty end ),
    ( if ($v.privileged // false) then "\($n): must not be privileged" else empty end )
  ),
  ( $reg | keys[] | select(. as $k | ($svc | has($k)) | not) | "register service \(.) does not exist in the compose project (stale entry)" )
' <<< "$JSON" | tr -d '\r')"

# Services with an image-defined user: the Dockerfile must set a numeric USER that is neither 0 nor 1000.
for pair in "${IMAGE_USER[@]}"; do
  svc="${pair%%:*}"
  df="${pair#*:}"
  jq -e --arg s "$svc" '.services | has($s)' <<< "$JSON" > /dev/null 2>&1 || continue
  u="$(grep -E '^USER[[:space:]]+[0-9]+:[0-9]+[[:space:]]*$' "$df" 2> /dev/null | tail -n 1 | awk '{print $2}' || true)"
  if ! [[ "$u" =~ ^([0-9]+):([0-9]+)$ ]] || [ "${BASH_REMATCH[1]}" -eq 0 ] || [ "${BASH_REMATCH[1]}" -eq 1000 ] || [ "${BASH_REMATCH[2]}" -eq 0 ] || [ "${BASH_REMATCH[2]}" -eq 1000 ]; then
    out="$(printf '%s\n%s: the Dockerfile %s must set USER <uid>:<gid> (not 0, not 1000)' "$out" "$svc" "$df")"
  fi
done

out="$(printf '%s\n' "$out" | grep -v '^$' || true)"
if [ -n "$out" ]; then
  printf 'Container rule violations (ADR-018, scripts/check-container-rules.sh):\n%s\n' "$out" >&2
  exit 1
fi
n="$(jq '.services | length' <<< "$JSON" | tr -d '\r')"
printf 'container rules OK: %s services, %s in the ADR-018 register\n' "$n" "$(jq 'length' <<< "$reg" | tr -d '\r')"
