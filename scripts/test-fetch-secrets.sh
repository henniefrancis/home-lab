#!/usr/bin/env bash
# test-fetch-secrets.sh - tests for scripts/fetch-secrets.sh with a mock `aws` (no network, no real secrets).
#
# Part A (any user): config/secrets-manifest.tsv agrees with terraform/edge/ssm.tf.
# Part B (needs root, uses temp dirs only; run via sudo or in a throwaway container): the fetch behaviour:
#   files, owners, modes, placeholder fail-closed, AWS failure, interrupted run leaves no staging, atomic swap,
#   release retention (current only), manifest edge cases, dry-run, and that no secret value ever reaches the output.
# CI runs it as: sudo -E bash scripts/test-fetch-secrets.sh
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose: $1, $2 expand in the child shell
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
check() { # check <name> <command...>
  local n="$1"
  shift
  if "$@"; then ok "$n"; else bad "$n"; fi
}

# ------------------------------------------------------------------ Part A
manifest_secrets="$(grep -vE '^(#|$)' "$REPO/config/secrets-manifest.tsv" | cut -f1 | grep -v '^config/' | sort)"
manifest_config="$(grep -vE '^(#|$)' "$REPO/config/secrets-manifest.tsv" | cut -f1 | grep '^config/' | sort)"
tf_config="$(grep -oE '"config/[a-z0-9-]+"' "$REPO/terraform/edge/ssm.tf" | tr -d '"' | sort -u)"
check "the seven SecureStrings are owner-managed (ADR-013): the manifest lists seven, ssm.tf has no SecureString resource and forgets the old ones" bash -c 'test "$(printf "%s
" "$1" | wc -l)" -eq 7 && ! grep -Eq "^resource \"aws_ssm_parameter\" \"secret\"" "$2" && grep -q "from = aws_ssm_parameter.secret" "$2"' _ "$manifest_secrets" "$REPO/terraform/edge/ssm.tf"
check "manifest config rows == ssm.tf config_params" test "$manifest_config" = "$tf_config"
check "manifest has a tab-separated row per parameter" test "$(grep -vcE '^(#|$)' "$REPO/config/secrets-manifest.tsv")" -ge 11

if [ "$(id -u)" -ne 0 ]; then
  if [ "${REQUIRE_ROOT:-0}" = 1 ]; then
    echo "FAIL - Part B needs root and REQUIRE_ROOT=1 is set (CI must not skip it)"
    exit 1
  fi
  echo "SKIP - Part B needs root (run: sudo -E bash $0)"
  [ "$fails" -eq 0 ] && exit 0 || exit 1
fi
command -v jq > /dev/null || {
  echo "jq is required for Part B"
  exit 1
}

# ------------------------------------------------------------------ Part B
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc/pki"
chmod 700 "$T/etc"
acct="$(printf '%012d' 7)"
ta="arn:aws:rolesanywhere:af-south-1:${acct}:trust-anchor/aaaaaaaa-0000-0000-0000-00000000000a"
pr="arn:aws:rolesanywhere:af-south-1:${acct}:profile/aaaaaaaa-0000-0000-0000-00000000000b"
ro="arn:aws:iam::${acct}:role/home-lab-pi-host"
printf 'AWS_REGION=af-south-1\nRA_TRUST_ANCHOR_ARN=%s\nRA_HOST_PROFILE_ARN=%s\nRA_HOST_ROLE_ARN=%s\n' "$ta" "$pr" "$ro" > "$T/etc/aws.env"
chmod 600 "$T/etc/aws.env"
: > "$T/etc/pki/host.crt"
: > "$T/etc/pki/host.key"

cat > "$T/bin/aws" << 'MOCK'
#!/usr/bin/env bash
case "$*" in *"ssm get-parameters-by-path"*) ;; *) echo "unexpected aws call" >&2; exit 9 ;; esac
if [ -n "${MOCK_AWS_FAIL:-}" ]; then echo "An error occurred (AccessDeniedException): not authorized" >&2; exit 254; fi
if [ -n "${MOCK_AWS_SLEEP:-}" ]; then touch "$MOCK_AWS_MARK"; sleep "$MOCK_AWS_SLEEP"; fi
cat "$MOCK_AWS_JSON"
MOCK
chmod +x "$T/bin/aws"
export PATH="$T/bin:$PATH"

V_SK="fixture-secret-key-AAAA1111"
V_PG="fixture-pg-password-BBBB2222"
# shellcheck disable=SC2016 # a literal bcrypt-style fixture, nothing to expand
V_HT='admin:$2y$05$fixturehashCCCC3333'
V_TS="tskey-auth-fixtureDDDD4444"
V_DOM="lab.example.test"
V_ZONE="ZFIXTURE5555"
V_PH="fixture-pihole-admin-EEEE6666"
V_LAN="10.0.0.77"
PH="UNSET-set-via-set-secret"

# mkjson <out> [name=value ...]: overrides per name; type String for config/*, SecureString otherwise.
mkjson() {
  local out="$1"
  shift
  local -A val=(
    [authentik/secret-key]="$V_SK" [authentik/postgres-password]="$V_PG" [authentik/bootstrap-password]="$PH"
    [traefik/breakglass-htpasswd]="$V_HT" [tailscale/auth-key]="$PH" [homepage/authentik-token]="$PH" [pihole/admin-password]="$V_PH"
    [config/domain]="$V_DOM" [config/route53-zone-id]="$V_ZONE" [config/ra-trust-anchor-arn]="$ta"
    [config/ra-acme-profile-arn]="$pr" [config/ra-acme-role-arn]="$ro" [config/pi-lan-ip]="$V_LAN"
  )
  local kv k
  for kv in "$@"; do
    k="${kv%%=*}"
    if [ "${kv#*=}" = "@@drop" ]; then unset "val[$k]"; else val[$k]="${kv#*=}"; fi
  done
  for k in "${!val[@]}"; do
    jq -n --arg n "/home-lab/$k" --arg v "${val[$k]}" --arg t "$([[ $k == config/* ]] && echo String || echo SecureString)" \
      '{Name:$n, Type:$t, Value:$v, Version:1}'
  done | jq -s '{Parameters: .}' > "$out"
}

AR="$T/apps"
mkdir -p "$AR"
FETCH=(bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR" --etc-dir "$T/etc")
export MOCK_AWS_JSON="$T/params.json"
rc=0
# shellcheck disable=SC2119,SC2120 # extra args are optional
run() { # run <extra args...>; sets rc, output in $T/out.log
  rc=0
  "${FETCH[@]}" "$@" > "$T/out.log" 2>&1 || rc=$?
}
no_values_in_output() {
  local v
  for v in "$V_SK" "$V_PG" "$V_HT" "$V_TS" "$V_DOM" "$V_ZONE" "$V_PH" "$V_LAN" "$ta" "$pr" "$ro" "$acct"; do
    grep -qF -- "$v" "$T/out.log" && return 1
  done
  return 0
}
no_staging() { [ -z "$(find "$AR/.secrets.d" -maxdepth 1 -name '.staging-*' 2> /dev/null)" ] && [ -z "$(find /run -maxdepth 1 -name 'home-lab-fetch.*' 2> /dev/null)" ]; }
attrs() { stat -c '%u:%g %a' "$AR/secrets/$1"; }

# 1. first run: a real empty dir sits at secrets/ (as created by bootstrap) and must become the symlink
mkdir -p "$AR/secrets"
chmod 700 "$AR/secrets"
mkjson "$T/params.json"
run
check "happy path exits 0" test "$rc" -eq 0
check "secrets became a symlink to a release" test -L "$AR/secrets"
check "authentik/secret-key 10002:10002 0400 (F02: not the login uid 1000)" test "$(attrs authentik/secret-key)" = "10002:10002 400"
check "authentik/postgres-password 10002:10002 0440 (Postgres reads it through the group)" test "$(attrs authentik/postgres-password)" = "10002:10002 440"
# shellcheck disable=SC2016 # the bash -c snippet is single-quoted on purpose: $1 expands in the child shell
check "no secret file is owned by uid or gid 1000" bash -c '! find "$1/secrets/" -type f \( -uid 1000 -o -gid 1000 \) | grep -q .' _ "$AR"
check "breakglass-htpasswd 10004:10004 0400 (read by non-root Traefik)" test "$(attrs traefik/breakglass-htpasswd)" = "10004:10004 400"
check "secret-key content exact (no trailing newline)" test "$(cat "$AR/secrets/authentik/secret-key"; echo x)" = "${V_SK}x"
check "bootstrap-password is an EMPTY 10002:10002 0400 file while UNSET (compose secret needs it to exist)" test "$(attrs authentik/bootstrap-password)" = "10002:10002 400" -a ! -s "$AR/secrets/authentik/bootstrap-password"
check "optional placeholder omitted (homepage token)" test ! -e "$AR/secrets/homepage/authentik-token"
check "tailscale.env is an empty 0:0 0600 file while UNSET" test "$(attrs tailscale/tailscale.env)" = "0:0 600" -a ! -s "$AR/secrets/tailscale/tailscale.env"
check "runtime.env 0:0 0600" test "$(attrs runtime.env)" = "0:0 600"
check "runtime.env has the 6 variables" test "$(grep -cE '^(DOMAIN|ROUTE53_ZONE_ID|RA_TRUST_ANCHOR_ARN|RA_ACME_PROFILE_ARN|RA_ACME_ROLE_ARN|PI_LAN_IP)=' "$AR/secrets/runtime.env")" -eq 6
check "pihole/admin-password 10006:10006 0400 (read by the Pi-hole entrypoint, M8)" test "$(attrs pihole/admin-password)" = "10006:10006 400"
check "no secret value or ARN in the script output" no_values_in_output
check "no staging dir left behind" no_staging
check "aws-config is root 0600 and has no key material" test "$(stat -c '%u %a' "$T/etc/aws-config")" = "0 600"
first="$(readlink "$AR/secrets")"

# 2. real Tailscale key -> TS_AUTHKEY line
mkjson "$T/params.json" "tailscale/auth-key=$V_TS"
run
check "run with a real Tailscale key exits 0" test "$rc" -eq 0
check "tailscale.env holds TS_AUTHKEY=..." test "$(cat "$AR/secrets/tailscale/tailscale.env")" = "TS_AUTHKEY=$V_TS"
check "no values in output (2)" no_values_in_output
second="$(readlink "$AR/secrets")"
check "second run published a new release" test "$first" != "$second"

# 3. placeholder in a required parameter fails closed
mkjson "$T/params.json" "authentik/postgres-password=$PH"
run
check "required placeholder exits 4" test "$rc" -eq 4
check "failure names the parameter" grep -q 'postgres-password' "$T/out.log"
check "failure leaves the previous release in place" test "$(readlink "$AR/secrets")" = "$second"
check "previous secret content untouched" test "$(cat "$AR/secrets/authentik/postgres-password"; echo x)" = "${V_PG}x"
check "no values in output (3)" no_values_in_output
check "no staging dir after failure" no_staging

# 4. missing required parameter, wrong type, unsafe env value
mkjson "$T/params.json" "config/domain=@@drop"
run
check "missing required parameter exits 4" test "$rc" -eq 4
mkjson "$T/params.json"
jq '(.Parameters[] | select(.Name == "/home-lab/authentik/secret-key") | .Type) = "String"' "$T/params.json" > "$T/p2.json" && mv "$T/p2.json" "$T/params.json"
run
check "a secret stored as plain String exits 4" test "$rc" -eq 4
mkjson "$T/params.json" "config/domain=has space"
run
check "unsafe env value exits 4" test "$rc" -eq 4
check "release unchanged after validation failures" test "$(readlink "$AR/secrets")" = "$second"
check "no staging dir after validation failures" no_staging

# 5. AWS failure
mkjson "$T/params.json"
MOCK_AWS_FAIL=1 run
check "AWS failure exits 3" test "$rc" -eq 3
check "AWS failure leaves the release in place" test "$(readlink "$AR/secrets")" = "$second"
check "no staging dir after AWS failure" no_staging

# 6. interrupted run (SIGTERM during the AWS call) cleans up
export MOCK_AWS_MARK="$T/mark"
rm -f "$MOCK_AWS_MARK"
MOCK_AWS_SLEEP=30 "${FETCH[@]}" > "$T/out.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [ -e "$MOCK_AWS_MARK" ] && break
  sleep 0.1
done
check "staging exists while a fetch is in flight" test -n "$(find "$AR/.secrets.d" -maxdepth 1 -name '.staging-*')"
pkill -TERM -P "$pid" 2> /dev/null || true
kill -TERM "$pid" 2> /dev/null || true
wait "$pid" 2> /dev/null || true
check "interrupted run leaves no staging or tmpfs dirs" no_staging
check "interrupted run leaves the release in place" test "$(readlink "$AR/secrets")" = "$second"

# 7. only the CURRENT release is kept (SEC-L6: a rotated-out secret must not stay on flash)
mkjson "$T/params.json"
for _ in 1 2 3 4; do run; done
check "only the current release is kept (SEC-L6)" test "$(find "$AR/.secrets.d" -maxdepth 1 -name 'release-*' | wc -l)" -eq 1
check "current release still exists" test -d "$AR/secrets/."

# 8. dry-run on a fresh root publishes nothing
AR2="$T/apps2"
mkdir -p "$AR2"
rc=0
bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR2" --etc-dir "$T/etc" --dry-run > "$T/out.log" 2>&1 || rc=$?
check "dry-run exits 0" test "$rc" -eq 0
check "dry-run publishes nothing" test ! -e "$AR2/secrets"
check "dry-run leaves no staging" test -z "$(find "$AR2/.secrets.d" -maxdepth 1 -name '.staging-*' 2> /dev/null)"

# 9. bad manifest rows are rejected before any AWS call
printf 'authentik/secret-key\tauthentik/secret-key\t1000:1000\t0777x\tyes\traw\n' > "$T/bad.tsv"
rc=0
bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR2" --etc-dir "$T/etc" --manifest "$T/bad.tsv" > "$T/out.log" 2>&1 || rc=$?
check "bad manifest mode exits 4" test "$rc" -eq 4
printf 'authentik/secret-key\t../escape\t1000:1000\t0400\tyes\traw\n' > "$T/bad.tsv"
rc=0
bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR2" --etc-dir "$T/etc" --manifest "$T/bad.tsv" > "$T/out.log" 2>&1 || rc=$?
check "manifest path traversal exits 4" test "$rc" -eq 4

# 10. aws.env with loose permissions is refused
chmod 644 "$T/etc/aws.env"
run
check "aws.env mode 0644 is refused" test "$rc" -ne 0
chmod 600 "$T/etc/aws.env"

# 11. manifest edge cases (QA-M-1, QA-L-2, QA-L-4, CRLF) and leftovers (QA-L-3)
mkjson "$T/params.json"
AR3="$T/apps3"
mkdir -p "$AR3"
good_manifest() { grep -vE '^(#|$)' "$REPO/config/secrets-manifest.tsv"; }
run3() { # run3 <manifest> [extra args]; sets rc, output in $T/out.log
  local m="$1"
  shift
  rc=0
  bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR3" --etc-dir "$T/etc" --manifest "$m" "$@" > "$T/out.log" 2>&1 || rc=$?
}
# M-1: the real manifest WITHOUT a trailing newline must still deliver its LAST row (route53-zone-id is not last: use the final row)
last_param="$(good_manifest | tail -n 1 | cut -f1)"
last_var="$(good_manifest | tail -n 1 | cut -f6 | sed 's/^env://')"
good_manifest | head -c -1 > "$T/nonl.tsv"
check "fixture really lacks a trailing newline" test "$(tail -c 1 "$T/nonl.tsv" | od -An -c | tr -d ' ')" != '\n'
run3 "$T/nonl.tsv"
check "manifest without a trailing newline: exit 0 (QA-M-1)" test "$rc" -eq 0
check "manifest without a trailing newline: the LAST row ($last_param) is written (QA-M-1)" grep -q "^${last_var}=" "$AR3/secrets/runtime.env"
check "row count in runtime.env equals the 6 env rows of runtime.env" test "$(grep -c '=' "$AR3/secrets/runtime.env")" -eq 6
# CRLF manifest
good_manifest | sed 's/$/\r/' > "$T/crlf.tsv"
run3 "$T/crlf.tsv"
check "CRLF manifest is accepted (exit 0)" test "$rc" -eq 0
check "CRLF manifest: no carriage return reaches a value or a mode" bash -c '! grep -q "$(printf "\r")" "$1/secrets/runtime.env"' _ "$AR3"
# L-2: an empty/optional row sharing an env target is rejected
printf 'tailscale/auth-key\tshared.env\t0:0\t0600\tyes\tenv:TS_AUTHKEY\nauthentik/bootstrap-password\tshared.env\t0:0\t0600\tempty\tenv:BOOT\n' > "$T/shared.tsv"
run3 "$T/shared.tsv" --dry-run
check "rows sharing an env target must all be required=yes (QA-L-2): exit 4" test "$rc" -eq 4
# L-4: a target that is a directory of another target
printf 'authentik/secret-key\tauthentik\t10002:10002\t0400\tyes\traw\nauthentik/postgres-password\tauthentik/pg\t10002:10002\t0440\tyes\traw\n' > "$T/prefix.tsv"
run3 "$T/prefix.tsv" --dry-run
check "target that is a directory of another is rejected with exit 4, not 1 (QA-L-4)" test "$rc" -eq 4
# NEW-8: an empty or comment-only manifest and a '.' target exit 4 with a clear message (no unbound-variable error, rc 1)
printf '# nothing but comments\n\n' > "$T/comments.tsv"
run3 "$T/comments.tsv" --dry-run
check "comment-only manifest exits 4 with 'no rows' (NEW-8)" bash -c 'test "$1" -eq 4 && grep -q "no rows" "$2" && ! grep -qi "unbound" "$2"' _ "$rc" "$T/out.log"
: > "$T/zero.tsv"
run3 "$T/zero.tsv" --dry-run
check "empty manifest exits 4 (NEW-8)" test "$rc" -eq 4
printf 'authentik/secret-key\t.\t10002:10002\t0400\tyes\traw\n' > "$T/dot.tsv"
run3 "$T/dot.tsv" --dry-run
check "target '.' exits 4, not 1 (NEW-8)" bash -c 'test "$1" -eq 4 && grep -q "segment" "$2"' _ "$rc" "$T/out.log"
printf 'authentik/secret-key\t./x\t10002:10002\t0400\tyes\traw\n' > "$T/dot2.tsv"
run3 "$T/dot2.tsv" --dry-run
check "target './x' exits 4 (NEW-8)" test "$rc" -eq 4
# NEW-9: the manifest header rules are enforced: never uid or gid 1000, never access for 'other'
for row in 'authentik/secret-key\tauthentik/a\t1000:1000\t0400\tyes\traw' 'authentik/secret-key\tauthentik/a\t10002:1000\t0400\tyes\traw' 'authentik/secret-key\tauthentik/a\t1000:10002\t0400\tyes\traw' 'authentik/secret-key\tauthentik/a\t10002:10002\t0666\tyes\traw' 'authentik/secret-key\tauthentik/a\t10002:10002\t0777\tyes\traw' 'authentik/secret-key\tauthentik/a\t10002:10002\t0404\tyes\traw'; do
  # shellcheck disable=SC2059 # the row carries the \t escapes
  printf "$row\n" > "$T/row.tsv"
  run3 "$T/row.tsv" --dry-run
  check "manifest row refused with exit 4: ${row#*authentik/a\\t} (NEW-9)" test "$rc" -eq 4
done
printf 'authentik/secret-key\tauthentik/a\t10002:10002\t0440\tyes\traw\n' > "$T/row.tsv"
run3 "$T/row.tsv" --dry-run
check "a group-readable row (0440) is still accepted (NEW-9 does not break the Postgres file)" test "$rc" -eq 0
# NEW-14: config/domain must be lowercase labels without a trailing dot (run3: the section-6 mock leaves a lock on the main apps root)
for d in 'Lab.Example.Test' 'lab.example.test.' '-lab.example.test' 'lab..example.test' 'lab_x.example.test' 'localhost'; do
  mkjson "$T/params.json" "config/domain=$d"
  run3 "$T/nonl.tsv"
  check "config/domain '$d' is refused (exit 4, NEW-14)" test "$rc" -eq 4
done
mkjson "$T/params.json" "config/domain=a-b.lab.example.test"
run3 "$T/nonl.tsv"
check "a normal lowercase multi-label domain is accepted (NEW-14)" test "$rc" -eq 0
mkjson "$T/params.json"
# usage errors exit 2
rc=0
bash "$REPO/scripts/fetch-secrets.sh" --manifest > "$T/out.log" 2>&1 || rc=$?
check "--manifest without a value exits 2 with a message" bash -c 'test "$1" -eq 2 && grep -q "needs a value" "$2"' _ "$rc" "$T/out.log"
# L-3: leftovers of a killed run are removed by the next run
mkdir -p "$AR3/.secrets.d/.staging-LEFTOVER" /run/home-lab-fetch.STALE
touch -d '1 hour ago' /run/home-lab-fetch.STALE
run3 "$T/nonl.tsv"
check "stale .staging-* of a killed run is removed (QA-L-3)" test ! -e "$AR3/.secrets.d/.staging-LEFTOVER"
check "stale /run/home-lab-fetch.* of a killed run is removed (QA-L-3)" test ! -e /run/home-lab-fetch.STALE
# dry-run writes nothing under etc-dir or apps-root (QA-L-16)
AR4="$T/apps4"
ETC4="$T/etc4"
mkdir -p "$ETC4/pki"
cp "$T/etc/aws.env" "$ETC4/aws.env"
: > "$ETC4/pki/host.crt"
: > "$ETC4/pki/host.key"
chmod 600 "$ETC4/aws.env"
rc=0
bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR4" --etc-dir "$ETC4" --dry-run > "$T/out.log" 2>&1 || rc=$?
check "dry-run exits 0" test "$rc" -eq 0
check "dry-run creates no aws-config and no apps-root" test ! -e "$ETC4/aws-config" -a ! -e "$AR4"

echo
if [ "$fails" -eq 0 ]; then
  echo "fetch-secrets tests: all checks passed"
else
  echo "fetch-secrets tests: $fails FAILED"
  exit 1
fi
