#!/usr/bin/env bash
# test-portainer-config.sh - self-test of the Portainer CE stack (R17, milestone M11). Needs docker (Compose v2.24+), jq, curl, openssl.
#
# Usage: scripts/test-portainer-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also runs the real image against this machine's Docker socket and the real Traefik routers (CI runs this)
#
# Dummy values only (lab.example.test, a throw-away admin password, a self-signed certificate, a stub outpost). Everything it creates is
# named pttest-* and removed on exit. The real Docker socket of the test machine is mounted, exactly like on the Pi (ADR-017).
#
# Static: pinned official image; root inside but cap_drop ALL with no cap_add, no-new-privileges, read-only root, limits; no published
#   port; proxy network only; the socket mounted (ADR-017) and no Docker provider; the command (HTTP on 9000, HTTPS and the Edge tunnel on
#   loopback, the local environment, the password file, the trusted origin); the manifest row, router with forward auth, Authentik
#   provider, tile, bootstrap directory, Dependabot.
# Full run: Portainer starts with the rendered definition; docker inspect confirms the hardening; from the proxy network the API answers on
#   9000 and 9443/8000 are not reachable; the password from the file logs in and a wrong one does not; the local Docker environment exists
#   and lists containers through the socket; through the REAL Traefik routers portainer.<domain> is behind forward auth and fails closed.
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
PW_T="pttest-$(openssl rand -hex 12)"
NET_PROXY=pttest-proxy
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f pttest-portainer pttest-traefik pttest-auth pttest-probe > /dev/null 2>&1 || true
    docker network rm "$NET_PROXY" > /dev/null 2>&1 || true
    docker volume rm pttest-data > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap "exit 130" INT TERM

stage="$(mktemp -d -p "${PORTAINER_TEST_TMP:-.}" .portainer-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })"
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole" "$stage/secrets/linkwarden" "$stage/secrets/portainer"
: > "$stage/secrets/tailscale/tailscale.env"
printf '%s' "$PW_T" > "$stage/secrets/portainer/admin-password"
chmod 644 "$stage/secrets/portainer/admin-password"
export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f portainer/compose.yaml --env-file config/lab.env config --format json)"
pt="$(jq -c '.services.portainer' <<< "$alone")"
IMAGE="$(jq -r '.image' <<< "$pt")"
printf 'image: %s\n' "$IMAGE"
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
cmd="$(jq -r '.command | join(" ")' <<< "$pt")"

echo "--- static: container definition"
check "image is the official portainer/portainer-ce X.Y.Z pinned by digest" bash -c '[[ "$1" =~ ^portainer/portainer-ce:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMAGE"
check "root compose includes portainer with the same image" test "$(jq -r '.services.portainer.image' <<< "$all")" = "$IMAGE"
check "cap_drop ALL, no cap_add, not privileged, no-new-privileges, read-only root, /tmp tmpfs" test "$(jq -c '[.cap_drop, (.cap_add // []), (.privileged // false), (.security_opt | index("no-new-privileges:true") != null), .read_only, .tmpfs]' <<< "$pt")" = '[["ALL"],[],false,true,true,["/tmp"]]'
check "memory and pid limits; no published port; proxy network only; no Traefik labels" test "$(jq -c '[(.mem_limit != null), .pids_limit, (.ports // [] | length), [.networks | keys[]], (.labels // {} | length)]' <<< "$pt")" = '[true,128,0,["proxy"],0]'
check "ADR-017: the Docker socket is mounted; the only other volume is APPS_ROOT/portainer/data at /data" bash -c '[ "$(jq -r "[.volumes[] | .target] | sort | join(\" \")" <<< "$1")" = "/data /var/run/docker.sock" ] && jq -r ".volumes[] | select(.target == \"/data\") | .source" <<< "$1" | tr "\\\\" / | grep -q "/portainer/data$"' _ "$pt"
check "HTTP on :9000 only; HTTPS on 127.0.0.1:9443 and the Edge tunnel on 127.0.0.1 (not reachable from other containers)" bash -c 'grep -q -- "--http-enabled --bind :9000 --bind-https 127.0.0.1:9443 --tunnel-addr 127.0.0.1 " <<< "$1"' _ "$cmd"
check "the local Docker environment is registered at start (--host unix:///var/run/docker.sock)" bash -c 'grep -q -- "--host unix:///var/run/docker.sock" <<< "$1"' _ "$cmd"
check "the admin password comes from the secret file; only https://portainer.<domain> is a trusted origin" bash -c 'grep -q -- "--admin-password-file /run/secrets/portainer_admin_password" <<< "$1" && grep -q -- "--trusted-origins https://portainer.lab.example.test " <<< "$1"' _ "$cmd"
check "manifest: portainer/admin-password, root-owned 0400, required" grep -qP '^portainer/admin-password\tportainer/admin-password\t0:0\t0400\tyes\traw$' config/secrets-manifest.tsv
check "portainer router: lan-allowlist then authentik, service portainer:9000; the outpost router has the dashboard's shape" bash -c 'b="$(router_block portainer)"; grep -q "Host(\`portainer.{{ env \"DOMAIN\" }}\`)" <<< "$b" && grep -A1 "middlewares:" <<< "$b" | grep -q -- "- lan-allowlist" && grep -q -- "- authentik$" <<< "$b" && awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://portainer:9000" && diff <(router_block dashboard-outpost | grep -Ev "rule:|^ *#|^$") <(router_block portainer-outpost | grep -Ev "rule:|^ *#|^$")' _ "$rt"
check "blueprint: provider homelab-portainer, admins only, in the embedded outpost" bash -c 'f=authentik/blueprints/homelab-apps.yaml; grep -q "name: homelab-portainer" $f && awk "/target: !KeyOf app-portainer/{getline; print}" $f | grep -q group-admins && awk "/managed: goauthentik.io\/outposts\/embedded/{f=1} f" $f | grep -q -- "- !KeyOf provider-portainer"'
check "Homepage tile live in Tools; bootstrap creates APPS_ROOT/portainer/data root 0700; Dependabot watches /portainer" bash -c 'awk "/^- Tools:/{f=1;next} /^- /{f=0} f" homepage/config/services.yaml | grep -q "href: https://portainer." && grep -q "install -d -m 0700 -o root -g root \"\$APPS_ROOT/portainer/data\"" scripts/bootstrap.sh && grep -q -- "- /portainer$" .github/dependabot.yml'

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Portainer checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
echo "--- containers"
docker network create "$NET_PROXY" > /dev/null
docker volume rm pttest-data > /dev/null 2>&1 || true # never reuse an interrupted run's data
docker volume create pttest-data > /dev/null
args=(--name pttest-portainer --network "$NET_PROXY" --network-alias portainer --read-only --cap-drop ALL --security-opt no-new-privileges:true
  --memory "$(jq -r '.mem_limit' <<< "$pt")" --pids-limit 128 --tmpfs /tmp -v pttest-data:/data -v /var/run/docker.sock:/var/run/docker.sock
  --mount "type=bind,source=$here/secrets/portainer/admin-password,target=/run/secrets/portainer_admin_password,readonly")
mapfile -t cmdv < <(jq -r '.command[]' <<< "$pt" | tr -d '\r')
docker run -d "${args[@]}" "$IMAGE" "${cmdv[@]}" > /dev/null
stub_img="$(awk '$1=="FROM" && $2 ~ /^nginxinc\/nginx-unprivileged:/ {print $2}' it-tools/Dockerfile)"
docker run -d --name pttest-probe --network "$NET_PROXY" --entrypoint sleep "$stub_img" 300 > /dev/null
pw() { docker exec pttest-probe wget -q -T 5 -O - "$@" 2> /dev/null; }
up=0
for _ in $(seq 1 30); do pw http://portainer:9000/api/status | grep -q '"Version"' && up=1 && break; sleep 2; done
check "Portainer answers on portainer:9000 with the rendered command" test "$up" = 1
check "docker inspect: read-only root, CapDrop ALL, no CapAdd, no-new-privileges, no port bindings" test "$(docker inspect pttest-portainer -f '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}} {{json .HostConfig.CapAdd}} {{json .HostConfig.SecurityOpt}} {{len .HostConfig.PortBindings}}')" = 'true ["ALL"] null ["no-new-privileges:true"] 0'
check "its HTTPS (9443) and Edge tunnel (8000) are not reachable from another container" bash -c '! docker exec pttest-probe wget -q -T 3 -O /dev/null --no-check-certificate https://portainer:9443/ 2>/dev/null && ! docker exec pttest-probe wget -q -T 3 -O /dev/null http://portainer:8000/ 2>/dev/null'
login() { docker exec pttest-probe wget -q -T 5 -O - --header 'Content-Type: application/json' --post-data "{\"username\":\"admin\",\"password\":\"$1\"}" http://portainer:9000/api/auth 2> /dev/null || true; }
jwt="$(login "$PW_T" | jq -r '.jwt // empty' 2> /dev/null || true)"
check "the password from the secret file logs in as admin" test -n "$jwt"
check "a wrong password does not" test -z "$(login wrong-password-x | jq -r '.jwt // empty' 2> /dev/null || true)"
eps="$(pw --header "Authorization: Bearer $jwt" http://portainer:9000/api/endpoints || true)"
check "the local Docker environment was registered at start (type 1, up)" test "$(jq -c '[.[] | [.Type, .Status]]' <<< "$eps" 2> /dev/null)" = '[[1,1]]'
eid="$(jq -r '.[0].Id // empty' <<< "$eps" 2> /dev/null || true)"
check "it lists containers through the socket (it sees itself), without any capability" bash -c 'docker exec pttest-probe wget -q -T 5 -O - --header "Authorization: Bearer $1" "http://portainer:9000/api/endpoints/$2/docker/containers/json" | jq -e "[.[].Names[]] | index(\"/pttest-portainer\") != null"' _ "$jwt" "$eid"

echo "--- through Traefik (real flags, routers and middlewares; stub outpost)"
printf 'server { listen 9000; location /outpost.goauthentik.io/auth/traefik { if ($http_cookie ~ "stub_session=ok") { return 200 "ok"; } return 302 https://auth.lab.example.test/application/o/authorize/?client_id=stub; } location / { return 404; } }\n' > "$stage/stub.conf"
chmod 644 "$stage/stub.conf"
acid="$(docker create --name pttest-auth --network "$NET_PROXY" --network-alias authentik-server "$stub_img" nginx -g 'daemon off;')"
docker cp "$here/stub.conf" "$acid:/etc/nginx/conf.d/default.conf"
docker start pttest-auth > /dev/null
timage="$(jq -r '.services.traefik.image' <<< "$all")"
mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$all" | tr -d '\r' | grep -Ev '^--(certificatesresolvers\.|entrypoints\.websecure\.http\.tls\.(certResolver|domains))')
flags+=(--entrypoints.websecure.http.tls=true)
mkdir -p "$stage/tr/dynamic"
cp traefik/dynamic/*.yml "$stage/tr/dynamic/"
sed -i '0,/- 10.0.0.0\/24/s//- 0.0.0.0\/0/' "$stage/tr/dynamic/middlewares.yml"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$here/tr/dynamic/test-k.pem" \
  -out "$here/tr/dynamic/test-c.pem" -days 2 -subj "/CN=*.${DOMAIN_T}" -addext "subjectAltName=DNS:*.${DOMAIN_T}" 2> /dev/null
printf 'tls:\n  certificates:\n    - certFile: /etc/traefik/dynamic/test-c.pem\n      keyFile: /etc/traefik/dynamic/test-k.pem\n' > "$stage/tr/dynamic/test-cert.yml"
chmod 644 "$stage/tr/dynamic/test-k.pem"
cid="$(docker create --name pttest-traefik --network "$NET_PROXY" -p 127.0.0.1::443 -e DOMAIN="$DOMAIN_T" --tmpfs /letsencrypt "$timage" "${flags[@]}")"
docker cp "$here/tr/." "$cid:/etc/traefik"
docker start "$cid" > /dev/null
hostport="$(docker port "$cid" 443/tcp | head -n 1 | sed 's/.*://')"
via() { curl -sk -o /dev/null -w '%{http_code}' --connect-to "portainer.$DOMAIN_T:443:127.0.0.1:$hostport" "$@" "https://portainer.$DOMAIN_T/api/status" || true; }
for _ in $(seq 1 30); do [ "$(via)" = 302 ] && break; sleep 2; done
check "anonymous request: 302 to the login (forward auth; Portainer not reached)" test "$(via)" = 302
check "with an accepted session Portainer answers through Traefik" test "$(via -H 'Cookie: stub_session=ok')" = 200
docker stop pttest-auth > /dev/null
c="$(via -H 'Cookie: stub_session=ok')"
check "Authentik down: Portainer is NOT served (fails closed: got $c)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$c"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Portainer checks passed\n'
