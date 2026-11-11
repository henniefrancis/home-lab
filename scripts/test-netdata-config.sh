#!/usr/bin/env bash
# test-netdata-config.sh - self-test of the Netdata stack (R17, milestone M10). Needs docker (Compose v2.24+), jq, curl, openssl.
#
# Usage: scripts/test-netdata-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also runs the real image with the host network. That needs a Linux Docker host whose PROXY_SUBNET (172.30.0.0/24) is free,
#              which the CI runner is; on Docker Desktop (Windows, macOS) the host network is not the machine's, so the container part is
#              skipped there with a message (the static part still runs).
#
# Dummy values only (lab.example.test, a self-signed certificate, a stub outpost). Everything it creates is named ndtest-* and removed.
#
# Static: pinned official image; host network and PID with exactly the listed capabilities (cap_drop ALL first); no published port; the
#   Docker socket mounted read-only and only here and in portainer/ (ADR-017); /proc, /sys and / read-only; netdata.conf mounted
#   read-only and binding ONLY to the proxy gateway and the loopback, allowing only those; telemetry, registry, ML and alerts off; router
#   with forward auth, Authentik provider, tile, bootstrap directories, Dependabot.
# Full run (Linux): the agent becomes healthy; it listens on 172.30.0.1:19999 and 127.0.0.1:19999 and nowhere else; a container on the
#   proxy network gets the API; a container on another Docker network is refused by "allow connections from"; the agent is not claimed
#   to Netdata Cloud and the telemetry opt-out marker exists; through the REAL Traefik routers netdata.<domain> is behind forward auth,
#   served with an accepted session, and fails closed when Authentik is down.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose: $1, $2 expand in the child shell
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
STATIC_ONLY=0
case "${1:-}" in
  --static) STATIC_ONLY=1 ;;
  '') ;;
  *)
    echo "usage: $0 [--static]" >&2
    exit 2
    ;;
esac
for t in docker jq curl openssl; do
  command -v "$t" > /dev/null || {
    echo "$t is required" >&2
    exit 2
  }
done
export MSYS_NO_PATHCONV=1
unset PROXY_SUBNET AUTHENTIK_AUTH_SUBNET OIDC_SUBNET APPS_ROOT DOMAIN AUTHENTIK_UID AUTHENTIK_GID AUTHENTIK_PG_UID AUTHENTIK_PG_GID HOMEPAGE_UID HOMEPAGE_GID TRAEFIK_UID TRAEFIK_GID ITTOOLS_UID ITTOOLS_GID PIHOLE_UID PIHOLE_GID PIHOLE_UPSTREAMS PI_LAN_IP LINKWARDEN_UID LINKWARDEN_GID TZ

fails=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  fails=$((fails + 1))
}
check() { # check <description> <command...>
  local d="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

DOMAIN_T=lab.example.test
NET_PROXY=ndtest-proxy
NET_OTHER=ndtest-other
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f ndtest-netdata ndtest-traefik ndtest-auth ndtest-in ndtest-out > /dev/null 2>&1 || true
    docker network rm "$NET_PROXY" "$NET_OTHER" > /dev/null 2>&1 || true
    docker volume rm ndtest-lib ndtest-cache > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap "exit 130" INT TERM

stage="$(mktemp -d -p "${NETDATA_TEST_TMP:-.}" .netdata-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })"
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole" "$stage/secrets/linkwarden"
: > "$stage/secrets/tailscale/tailscale.env"
export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f netdata/compose.yaml --env-file config/lab.env config --format json)"
nd="$(jq -c '.services.netdata' <<< "$alone")"
IMAGE="$(jq -r '.image' <<< "$nd")"
printf 'image: %s\n' "$IMAGE"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2-; }
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
conf=netdata/netdata.conf
ini() { awk -v s="[$1]" -v k="$2" '$0 == s {f=1; next} /^\[/ {f=0} f && $1 != "#" { line=$0; sub(/^[ \t]+/, "", line); n=index(line, "="); if (n && substr(line, 1, n-1) ~ "^" k "[ \t]*$") { v=substr(line, n+1); sub(/^[ \t]+/, "", v); print v } }' "$conf"; }
gw="$(lab_get PROXY_SUBNET | sed -E 's#^([0-9]+\.[0-9]+\.[0-9]+)\.0/24$#\1.1#')"
pfx="$(lab_get PROXY_SUBNET | sed -E 's#^([0-9]+\.[0-9]+\.[0-9]+)\.0/24$#\1.*#')"

echo "--- static: container definition"
check "image is the official netdata/netdata vX.Y.Z pinned by digest" bash -c '[[ "$1" =~ ^netdata/netdata:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMAGE"
check "root compose includes netdata with the same image" test "$(jq -r '.services.netdata.image' <<< "$all")" = "$IMAGE"
check "host network and host PID (as the official setup; host network statistics)" test "$(jq -r '.network_mode + " " + .pid' <<< "$nd")" = "host host"
check "cap_drop ALL and exactly SYS_PTRACE SYS_ADMIN SETUID SETGID CHOWN DAC_OVERRIDE DAC_READ_SEARCH FOWNER; not privileged" test "$(jq -c '[.cap_drop, (.cap_add | sort), (.privileged // false)]' <<< "$nd")" = '[["ALL"],["CHOWN","DAC_OVERRIDE","DAC_READ_SEARCH","FOWNER","SETGID","SETUID","SYS_ADMIN","SYS_PTRACE"],false]'
check "no NET_ADMIN, NET_RAW, SYS_MODULE, SYS_RAWIO (no network or kernel changes)" bash -c '! jq -r ".cap_add[]" <<< "$1" | grep -Eq "NET_ADMIN|NET_RAW|SYS_MODULE|SYS_RAWIO|SYS_TIME"' _ "$nd"
check "no published port (host network; the bind address in netdata.conf is the only way in)" test "$(jq '.ports // [] | length' <<< "$nd")" = 0
check "the Docker socket is mounted read-only (ADR-017)" test "$(jq -c '[.volumes[] | select(.source == "/var/run/docker.sock") | .read_only]' <<< "$nd")" = '[true]'
check "the host's /, /proc and /sys are mounted read-only" test "$(jq -c '[.volumes[] | select(.target == "/host/root" or .target == "/host/proc" or .target == "/host/sys") | .read_only] | unique' <<< "$nd")" = '[true]'
check "netdata.conf is mounted read-only from the repo at /etc/netdata/netdata.conf" bash -c 'jq -e ".volumes[] | select(.target == \"/etc/netdata/netdata.conf\" and .read_only == true)" <<< "$1"' _ "$nd"
check "lib and cache live under APPS_ROOT/netdata (no named volumes)" test "$(jq -c '[.volumes[] | select(.target == "/var/lib/netdata" or .target == "/var/cache/netdata") | .type] | unique' <<< "$nd")" = '["bind"]'
check "telemetry off (DISABLE_TELEMETRY and DO_NOT_TRACK)" test "$(jq -r '.environment.DISABLE_TELEMETRY + .environment.DO_NOT_TRACK' <<< "$nd")" = 11
check "memory and pid limits set" test "$(jq -c '[.mem_limit != null, .pids_limit]' <<< "$nd")" = '[true,512]'
check "ADR-017: no other stack mounts the Docker socket (comment lines aside)" bash -c '! git grep -nE "docker[.]sock" -- "*/compose.yaml" compose.yaml | grep -v ":[0-9]*:[[:space:]]*#" | cut -d: -f1 | grep -vE "^(netdata|portainer)/compose.yaml$"'

echo "--- static: netdata.conf (exposure)"
check "bind to = the proxy gateway ($gw) and the loopback only, both port 19999, dashboard only" test "$(ini web 'bind to')" = "$gw:19999=dashboard 127.0.0.1:19999=dashboard"
check "allow connections from / allow dashboard from = localhost and the proxy subnet only ($pfx)" test "$(ini web 'allow connections from')|$(ini web 'allow dashboard from')" = "localhost $pfx|localhost $pfx"
check "management, badges and netdata.conf only from localhost; streaming from nobody" test "$(ini web 'allow management from')|$(ini web 'allow badges from')|$(ini web 'allow netdata.conf from')|$(ini web 'allow streaming from')" = 'localhost|localhost|localhost|!*'
check "registry, machine learning and Netdata's own alerts are off" test "$(ini registry enabled)$(ini ml enabled)$(ini health enabled)" = nonono
check "dbengine with three tiers capped at 1 GiB in total (SD-card wear)" test "$(ini db mode) $(ini db 'storage tiers') $(ini db 'dbengine tier 0 retention size') $(ini db 'dbengine tier 1 retention size') $(ini db 'dbengine tier 2 retention size')" = "dbengine 3 512MiB 256MiB 256MiB"

echo "--- static: router, Authentik, tile, host"
check "netdata router: lan-allowlist then authentik; service netdata at http://$gw:19999 (the bind address)" bash -c 'b="$(router_block netdata)"; grep -q "Host(\`netdata.{{ env \"DOMAIN\" }}\`)" <<< "$b" && grep -q "service: netdata$" <<< "$b" && grep -A1 "middlewares:" <<< "$b" | grep -q -- "- lan-allowlist" && grep -q -- "- authentik$" <<< "$b" && awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://$2:19999"' _ "$rt" "$gw"
check "netdata-outpost router has the dashboard's shape" bash -c 'diff <(router_block dashboard-outpost | grep -Ev "rule:|^ *#|^$") <(router_block netdata-outpost | grep -Ev "rule:|^ *#|^$")' _
check "blueprint: provider homelab-netdata (forward_single), admins only, in the embedded outpost" bash -c 'f=authentik/blueprints/homelab-apps.yaml; grep -q "name: homelab-netdata" $f && awk "/target: !KeyOf app-netdata/{getline; print}" $f | grep -q group-admins && awk "/managed: goauthentik.io\/outposts\/embedded/{f=1} f" $f | grep -q -- "- !KeyOf provider-netdata"'
check "Homepage tile live in Tools; bootstrap creates APPS_ROOT/netdata/lib and cache; Dependabot watches /netdata" bash -c 'awk "/^- Tools:/{f=1;next} /^- /{f=0} f" homepage/config/services.yaml | grep -q "href: https://netdata." && grep -q "netdata/lib\" \"\$APPS_ROOT/netdata/cache\"" scripts/bootstrap.sh && grep -q -- "- /netdata$" .github/dependabot.yml'

if [ "$STATIC_ONLY" -eq 0 ]; then
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN* | Darwin)
      echo "SKIP  container run: this Docker host's 'host network' is not this machine's (Docker Desktop); CI runs it on Linux"
      STATIC_ONLY=1
      ;;
  esac
fi
if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Netdata checks passed\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
echo "--- containers (Linux host network)"
docker network create --subnet "$(lab_get PROXY_SUBNET)" "$NET_PROXY" > /dev/null
docker network create "$NET_OTHER" > /dev/null
docker volume rm ndtest-lib ndtest-cache > /dev/null 2>&1 || true # never reuse an interrupted run's data
docker volume create ndtest-lib > /dev/null
docker volume create ndtest-cache > /dev/null
args=(--name ndtest-netdata --network host --pid host --hostname homelab-pi --cap-drop ALL --memory "$(jq -r '.mem_limit' <<< "$nd")" --pids-limit 512
  -v ndtest-lib:/var/lib/netdata -v ndtest-cache:/var/cache/netdata)
while IFS= read -r l; do args+=(--cap-add "$l"); done < <(jq -r '.cap_add[]' <<< "$nd")
while IFS= read -r l; do args+=(-e "$l"); done < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<< "$nd")
while IFS=$'\t' read -r src tgt ro; do
  case "$tgt" in /var/lib/netdata | /var/cache/netdata) continue ;; esac
  args+=(-v "$src:$tgt$([ "$ro" = true ] && echo ':ro')")
done < <(jq -r '.volumes[] | [.source, .target, (.read_only // false)] | @tsv' <<< "$nd")
docker run -d "${args[@]}" "$IMAGE" > /dev/null
healthy=0
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' ndtest-netdata 2> /dev/null)" = healthy ] && healthy=1 && break
  sleep 3
done
check "the agent becomes healthy with the rendered definition" test "$healthy" = 1
listen="$(ss -H -tln 2> /dev/null | awk '{print $4}' | grep -E ':19999$' | sort -u | tr '\n' ' ')"
check "it listens on $gw:19999 and 127.0.0.1:19999 only, never on 0.0.0.0 or IPv6 [$listen]" test "$listen" = "127.0.0.1:19999 $gw:19999 "
stub_img="$(awk '$1=="FROM" && $2 ~ /^nginxinc\/nginx-unprivileged:/ {print $2}' it-tools/Dockerfile)"
docker run -d --name ndtest-in --network "$NET_PROXY" --entrypoint sleep "$stub_img" 300 > /dev/null
docker run -d --name ndtest-out --network "$NET_OTHER" --entrypoint sleep "$stub_img" 300 > /dev/null
check "a container on the proxy network gets the API (as Traefik does)" bash -c 'docker exec ndtest-in wget -q -T 5 -O - "http://$1:19999/api/v1/info" | grep -q "\"version\""' _ "$gw"
check "a container on another Docker network is refused (allow connections from)" bash -c '! docker exec ndtest-out wget -q -T 5 -O /dev/null "http://$1:19999/api/v1/info"' _ "$gw"
check "the main daemon does not run as root" bash -c '[ "$(docker exec ndtest-netdata sh -c "awk \"/^Uid:/{print \\\$2}\" /proc/\$(pidof netdata | cut -d\" \" -f1)/status")" != 0 ]'
check "not claimed to Netdata Cloud (no claimed_id) and the telemetry opt-out marker exists" bash -c '! docker exec ndtest-netdata sh -c "test -s /var/lib/netdata/cloud.d/claimed_id" && docker exec ndtest-netdata test -e /etc/netdata/.opt-out-from-anonymous-statistics'

echo "--- through Traefik (real flags, routers and middlewares; stub outpost)"
printf 'server { listen 9000; location /outpost.goauthentik.io/auth/traefik { if ($http_cookie ~ "stub_session=ok") { return 200 "ok"; } return 302 https://auth.lab.example.test/application/o/authorize/?client_id=stub; } location / { return 404; } }\n' > "$stage/stub.conf"
chmod 644 "$stage/stub.conf"
acid="$(docker create --name ndtest-auth --network "$NET_PROXY" --network-alias authentik-server "$stub_img" nginx -g 'daemon off;')"
docker cp "$here/stub.conf" "$acid:/etc/nginx/conf.d/default.conf"
docker start ndtest-auth > /dev/null
timage="$(jq -r '.services.traefik.image' <<< "$all")"
mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$all" | grep -Ev '^--(certificatesresolvers\.|entrypoints\.websecure\.http\.tls\.(certResolver|domains))')
flags+=(--entrypoints.websecure.http.tls=true)
mkdir -p "$stage/tr/dynamic"
cp traefik/dynamic/*.yml "$stage/tr/dynamic/"
sed -i '0,/- 10.0.0.0\/24/s//- 0.0.0.0\/0/' "$stage/tr/dynamic/middlewares.yml"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$here/tr/dynamic/test-k.pem" \
  -out "$here/tr/dynamic/test-c.pem" -days 2 -subj "/CN=*.${DOMAIN_T}" -addext "subjectAltName=DNS:*.${DOMAIN_T}" 2> /dev/null
printf 'tls:\n  certificates:\n    - certFile: /etc/traefik/dynamic/test-c.pem\n      keyFile: /etc/traefik/dynamic/test-k.pem\n' > "$stage/tr/dynamic/test-cert.yml"
chmod 644 "$stage/tr/dynamic/test-k.pem"
cid="$(docker create --name ndtest-traefik --network "$NET_PROXY" -p 127.0.0.1::443 -e DOMAIN="$DOMAIN_T" --tmpfs /letsencrypt "$timage" "${flags[@]}")"
docker cp "$here/tr/." "$cid:/etc/traefik"
docker start "$cid" > /dev/null
hostport="$(docker port "$cid" 443/tcp | head -n 1 | sed 's/.*://')"
via() { curl -sk -o /dev/null -w '%{http_code}' --connect-to "netdata.$DOMAIN_T:443:127.0.0.1:$hostport" "$@" "https://netdata.$DOMAIN_T/api/v1/info" || true; }
for _ in $(seq 1 30); do [ "$(via)" = 302 ] && break; sleep 2; done
check "anonymous request: 302 to the login (forward auth; Netdata not reached)" test "$(via)" = 302
check "with an accepted session Netdata's API answers through Traefik" test "$(via -H 'Cookie: stub_session=ok')" = 200
docker stop ndtest-auth > /dev/null
c="$(via -H 'Cookie: stub_session=ok')"
check "Authentik down: Netdata is NOT served (fails closed: got $c)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$c"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Netdata checks passed\n'
