#!/usr/bin/env bash
# test-homepage-config.sh - self-test of the Homepage stack definition (milestone M5). Needs docker (Compose v2.24+), jq and curl.
#
# Usage: scripts/test-homepage-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (fast, no containers; this is what CI runs)
#   (default)  also boots a throw-away copy of the path (about 1 minute on a laptop or runner, no Pi, no Authentik needed).
#
# Dummy values only: a fake domain (lab.example.test), a self-signed wildcard certificate, a stub in place of the Authentik
# outpost. Nothing is sent to ACME, AWS or any real host. Everything it creates is named hmtest-* and removed on exit.
# (The Authentik side of forward auth is proven by scripts/test-authentik-config.sh; this test proves that Homepage's own
# routers send every request through that middleware and that its outpost callback router is wired like the dashboard's.)
#
# Static checks (plan 6.6): pinned image (by digest), dedicated uid, read-only root, hardening, no published port, no docker.sock and
#   no Docker integration of any kind (SEC-H2: the socket proxy and the status add-on are gone), only the proxy network,
#   HOMEPAGE_ALLOWED_HOSTS, logs to stdout, the routers in traefik/dynamic/routers.yml (allowlist then authentik, outpost router),
#   committed config (all files present, domain only through {{HOMEPAGE_VAR_DOMAIN}}, no docker server, update check off),
#   service ids consistent between lab.env, secrets-manifest.tsv and bootstrap.sh, root compose includes it.
# Full run: Homepage boots as uid 10003 with a read-only root file system and the config mounted read-only; it renders with the
#   dummy domain and has no Docker data source; HOMEPAGE_ALLOWED_HOSTS rejects other hosts; the REAL Traefik flags, the REAL
#   routers.yml and middlewares answer an anonymous request with the login redirect (302 from forward auth, Homepage never
#   reached), serve it only with the auth header result, never serve the apex or www, and the outpost callback path goes to the
#   outpost (not to Homepage).
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
command -v docker > /dev/null || {
  echo "docker is required" >&2
  exit 2
}
command -v jq > /dev/null || {
  echo "jq is required" >&2
  exit 2
}
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: keep "container:/path" arguments intact
# Hermetic: the shell environment would win over --env-file, so drop anything that lab.env defines.
unset PROXY_SUBNET AUTHENTIK_AUTH_SUBNET APPS_ROOT DOMAIN AUTHENTIK_UID AUTHENTIK_GID AUTHENTIK_PG_UID AUTHENTIK_PG_GID HOMEPAGE_UID HOMEPAGE_GID TRAEFIK_UID TRAEFIK_GID TZ

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
NET_PROXY=hmtest-proxy
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0 # debugging: leave the hmtest-* containers and networks (remove them by hand afterwards)
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f hmtest-traefik hmtest-homepage hmtest-auth > /dev/null 2>&1 || true
    docker network rm "$NET_PROXY" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT

# --------------------------------------------------------------------------------------------------------------------
# Static review. The root project is rendered (as deploy.sh does) and homepage/compose.yaml alone (--only homepage).
# --------------------------------------------------------------------------------------------------------------------
# Scratch directory (holds a throw-away TLS test key): HOMEPAGE_TEST_TMP (for example a scratchpad) or, by default, the checkout
# (git-ignored: .homepage-test.*/).
stage="$(mktemp -d -p "${HOMEPAGE_TEST_TMP:-.}" .homepage-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })" # a path docker.exe understands under Git Bash, plain pwd elsewhere
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik"
: > "$stage/secrets/tailscale/tailscale.env"

export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f homepage/compose.yaml --env-file config/lab.env config --format json)"
hp="$(jq -c '.services.homepage' <<< "$alone")"
IMAGE="$(jq -r '.image' <<< "$hp")"
printf 'image: %s\n' "$IMAGE"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2; }
manifest_owner() { awk -F'\t' -v p="$1" '$1 == p {print $3 " " $4}' config/secrets-manifest.tsv; }
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
cfgfile() { printf 'homepage/config/%s' "$1"; }

echo "--- static: container definition"
check "image is a pinned ghcr.io/gethomepage/homepage vX.Y.Z, by digest (not latest, not a bare major, SEC-M5)" bash -c '[[ "$1" =~ ^ghcr\.io/gethomepage/homepage:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMAGE"
check "root compose includes homepage, and --only homepage renders the same service" test "$(jq -r '.services.homepage.image' <<< "$all")" = "$IMAGE"
check "runs as HOMEPAGE_UID:HOMEPAGE_GID = 10003:10003 (not root, not the login user 1000)" test "$(jq -r '.user' <<< "$hp")" = "10003:10003" -a "$(lab_get HOMEPAGE_UID):$(lab_get HOMEPAGE_GID)" = "10003:10003"
check "read-only root file system; only two tmpfs mounts (/tmp, the Next.js cache), both owned by the service uid" test "$(jq -c '[.read_only, (.tmpfs | map(split(":")[0]) | sort), ([.tmpfs[] | select(contains("uid=10003,gid=10003"))] | length)]' <<< "$hp")" = '[true,["/app/.next/cache","/tmp"],2]'
check "cap_drop ALL, no cap_add, not privileged, no-new-privileges" test "$(jq -c '[.cap_drop, (.cap_add // []), (.privileged // false), (.security_opt | index("no-new-privileges:true") != null)]' <<< "$hp")" = '[["ALL"],[],false,true]'
check "memory limit set (384M)" test "$(jq -r '.mem_limit' <<< "$hp")" = "402653184"
check "no published ports (reached through Traefik only)" test "$(jq '.ports // [] | length' <<< "$hp")" = 0
check "docker.sock is mounted nowhere in the Homepage service, and DOCKER_HOST is not set" bash -c '! jq -r ".volumes[]? | .source" <<< "$1" | grep -q "docker.sock" && [ "$(jq -r ".environment.DOCKER_HOST // \"none\"" <<< "$1")" = none ]' _ "$hp"
check "the only volume is the committed config, read-only (no data directory, nothing written into the checkout)" test "$(jq -c '[.volumes[] | [.target, .read_only]]' <<< "$hp")" = '[["/app/config",true]]'
check "Homepage is on the proxy network ONLY (no socket-proxy network, no Docker integration)" test "$(jq -c '[.networks | keys[]]' <<< "$hp")" = '["proxy"]' -a "$(jq -r '.networks.proxy.external' <<< "$alone")" = true
check "no Docker integration: HOMEPAGE_VAR_DOCKER_SERVER is not set and config/docker.yaml defines no server" test "$(jq -r '.environment.HOMEPAGE_VAR_DOCKER_SERVER // "unset"' <<< "$hp")" = "unset" -a "$(grep -vc '^\s*#\|^---\|^\s*$' "$(cfgfile docker.yaml)" || true)" = 0
check "the status add-on is gone (SEC-H2): no compose.docker-status.yaml, no docker-status directory, nothing names socket-proxy outside comments" bash -c '[ ! -e homepage/compose.docker-status.yaml ] && [ ! -e homepage/docker-status ] && ! grep -rhv "^\s*#" homepage/compose.yaml homepage/config | grep -q "socket-proxy"' _
check "HOMEPAGE_ALLOWED_HOSTS is exactly dashboard.<domain> (no wildcard)" test "$(jq -r '.environment.HOMEPAGE_ALLOWED_HOSTS' <<< "$hp")" = "dashboard.$DOMAIN_T"
check "HOMEPAGE_VAR_DOMAIN carries the domain; logs go to stdout only" test "$(jq -c '[.environment.HOMEPAGE_VAR_DOMAIN, .environment.LOG_TARGETS]' <<< "$hp")" = "[\"$DOMAIN_T\",\"stdout\"]"
check "log rotation json-file 10m x 3" test "$(jq -c '[.logging.driver, .logging.options["max-size"], .logging.options["max-file"]]' <<< "$hp")" = '["json-file","10m","3"]'
check "no secret in the environment (the optional token would be a file: HOMEPAGE_FILE_*)" bash -c '! jq -r ".environment | keys[]" <<< "$1" | grep -Eiq "token|password|secret|key"' _ "$hp"

echo "--- static: routers (traefik/dynamic/routers.yml)"
check "homepage carries no Traefik labels (its routers are files, SEC-H2)" test "$(jq '.labels // {} | length' <<< "$hp")" = 0
check "homepage router: dashboard.<domain> through the DOMAIN template, websecure, lan-allowlist then authentik, service homepage, no basic auth" bash -c 'b="$(router_block homepage)"; grep -q "Host(\`dashboard.{{ env \"DOMAIN\" }}\`)" <<< "$b" && grep -q "websecure" <<< "$b" && grep -q "service: homepage" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 2 ] && grep -q -- "- lan-allowlist" <<< "$b" && grep -q -- "- authentik$" <<< "$b" && ! grep -qi basic <<< "$b"' _
check "homepage service points at http://homepage:3000" bash -c 'awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://homepage:3000"' _ $rt
check "homepage-outpost router: app host + /outpost.goauthentik.io/ -> service authentik, priority 100, allowlist only" bash -c 'b="$(router_block homepage-outpost)"; grep -q "dashboard.{{ env" <<< "$b" && grep -q "PathPrefix" <<< "$b" && grep -q "/outpost.goauthentik.io/" <<< "$b" && grep -q "priority: 100" <<< "$b" && grep -q "service: authentik$" <<< "$b" && grep -q -- "- lan-allowlist$" <<< "$b" && ! grep -q -- "- authentik$" <<< "$b"' _
check "same shape as the Traefik dashboard's outpost router (consistent with M4)" bash -c 'diff <(router_block dashboard-outpost | grep -Ev "rule:|^ *#|^$") <(router_block homepage-outpost | grep -Ev "rule:|^ *#|^$")' _
rules="$(grep -h "rule:" traefik/dynamic/*.yml | sed 's/{{ env "DOMAIN" }}/lab.example.test/g')"
check "no router for the apex or www anywhere in the lab" bash -c '! grep -Eq "Host\(.(www\.)?lab\.example\.test.\)" <<< "$1"' _ "$rules"
check "every host in a Traefik rule of the lab is a subdomain of the lab domain (apex and www are not served)" bash -c '! grep -o "Host([^)]*)" <<< "$1" | grep -Ev "Host\(.[a-z0-9-]+\.lab\.example\.test.\)" | grep -q .' _ "$rules"
check "Authentik blueprint already has the dashboard provider, application and group binding (no blueprint change needed)" bash -c 'grep -q "name: homelab-dashboard" "$1" && grep -q "slug: dashboard" "$1" && grep -q "external_host: !Format \[\"https://dashboard.%s\", !Env DOMAIN\]" "$1"' _ authentik/blueprints/homelab-apps.yaml

echo "--- static: committed config"
for f in settings services widgets bookmarks docker kubernetes proxmox; do
  check "config/$f.yaml exists (the app never tries to copy its skeleton into the read-only mount)" test -f "$(cfgfile $f.yaml)"
done
check "config/custom.css and custom.js exist" test -f "$(cfgfile custom.css)" -a -f "$(cfgfile custom.js)"
check "config files use only {{HOMEPAGE_VAR_DOMAIN}}: no literal domain, IP or lab.env value (public vendor doc links only)" bash -c '! grep -rEn "([0-9]{1,3}\.){3}[0-9]{1,3}|example\.test|\.(com|net|org|io|dev|co\.za)/" homepage/config | grep -Ev "gethomepage\.dev|doc\.traefik\.io|docs\.goauthentik\.io|^[^:]+:[0-9]+:\s*#"'
check "tiles are plain links: no docker server or container key anywhere in services.yaml (SEC-H2)" bash -c '! grep -Eq "^\s*(server|container):" "$1" && ! grep -q "HOMEPAGE_VAR_DOCKER_SERVER" "$1"' _ "$(cfgfile services.yaml)"
for h in traefik auth ha tools links netdata pihole portainer; do
  check "tile href https://$h.{{HOMEPAGE_VAR_DOMAIN}}/" grep -q "href: https://$h\.{{HOMEPAGE_VAR_DOMAIN}}/" "$(cfgfile services.yaml)"
done
check "the five services still to come are in the Coming soon group, IT Tools (M7) is live in Tools" bash -c 'awk "/^- Coming soon:/{f=1} f" "$1" | grep -c "href:" | grep -qx 5 && awk "/^- Tools:/{f=1;next} /^- /{f=0} f" "$1" | grep -q "href: https://tools\."' _ "$(cfgfile services.yaml)"
check "settings: update check off, version hidden" bash -c 'grep -qx "disableUpdateCheck: true" "$1" && grep -qx "hideVersion: true" "$1"' _ "$(cfgfile settings.yaml)"
check "widgets make no external request (no search, weather or API widget)" bash -c '! grep -Eq "^- (search|openmeteo|openweathermap|weatherapi|glances|unifi)" "$1"' _ "$(cfgfile widgets.yaml)"
check "no HOMEPAGE_FILE_/key placeholder in committed config (the Authentik widget is opt-in: runbook)" bash -c '! grep -rq "HOMEPAGE_FILE_\|HOMEPAGE_VAR_.*KEY" homepage/config' _

echo "--- static: service ids"
check "lab.env: HOMEPAGE_UID/GID 10003, not 0 and not 1000" test "$(lab_get HOMEPAGE_UID) $(lab_get HOMEPAGE_GID)" = "10003 10003"
check "manifest: homepage/authentik-token 10003:10003 0400, optional (required = no)" test "$(manifest_owner homepage/authentik-token)" = "10003:10003 0400" -a "$(awk -F'\t' '$1 == "homepage/authentik-token" {print $5}' config/secrets-manifest.tsv)" = no
check "bootstrap.sh validates the Homepage ids (numeric, not 0, not 1000) and preflight.sh checks them against host users" bash -c 'grep -q "HOMEPAGE_UID" scripts/bootstrap.sh && grep -q "HOMEPAGE_GID" scripts/bootstrap.sh && grep -q "HOMEPAGE_UID HOMEPAGE_GID" scripts/preflight.sh' _
check "deploy.sh --only homepage resolves homepage/compose.yaml (stack name is a plain directory name)" bash -c 'grep -q "COMPOSE_FILE=\"\$REPO_DIR/\$ONLY/compose.yaml\"" scripts/deploy.sh && [ -f homepage/compose.yaml ]' _

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Homepage checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
# Containers: the REAL Homepage definition (image, user, tmpfs, limits, environment, the committed config mounted read-only),
# the REAL Traefik flags, routers and middlewares, a stub for the Authentik outpost.
# --------------------------------------------------------------------------------------------------------------------
echo "--- containers"
docker network create "$NET_PROXY" > /dev/null

# 1. Homepage, built from the rendered definition (proxy network only; network alias homepage = the service url in routers.yml).
start_homepage() { # start_homepage <service json>
  local j="$1" l src tgt _ro
  local args=(--name hmtest-homepage --network "$NET_PROXY" --network-alias homepage --user "$(jq -r '.user' <<< "$j")" --read-only --cap-drop ALL
    --security-opt no-new-privileges:true --memory "$(jq -r '.mem_limit' <<< "$j")")
  while IFS= read -r l; do args+=(--tmpfs "$l"); done < <(jq -r '.tmpfs[]' <<< "$j" | tr -d '\r')
  while IFS= read -r l; do args+=(-e "$l"); done < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<< "$j" | tr -d '\r')
  while IFS=$'\t' read -r src tgt _ro; do args+=(--mount "type=bind,source=$src,target=$tgt,readonly"); done < <(jq -r '.volumes[] | [.source, .target, .read_only] | @tsv' <<< "$j" | tr -d '\r')
  docker create "${args[@]}" "$IMAGE" > /dev/null
  docker start hmtest-homepage > /dev/null
}
start_homepage "$hp"

# 2. Stub for the Authentik embedded outpost (name authentik-server on the proxy network, port 9000): answers forward auth with
#    the login redirect unless the request carries the cookie stub_session=ok; any other outpost path answers OUTPOST-STUB.
stub_js='
const http = require("http");
http.createServer((q, s) => {
  if (q.url.startsWith("/outpost.goauthentik.io/auth/traefik")) {
    if ((q.headers.cookie || "").includes("stub_session=ok")) { s.writeHead(200, {"X-authentik-username": "tester"}); return s.end("ok"); }
    s.writeHead(302, {Location: "https://auth.lab.example.test/application/o/authorize/?client_id=stub"}); return s.end("login");
  }
  if (q.url.startsWith("/outpost.goauthentik.io/")) { s.writeHead(200); return s.end("OUTPOST-STUB"); }
  s.writeHead(404); s.end();
}).listen(9000);'
docker run -d --name hmtest-auth --network "$NET_PROXY" --network-alias authentik-server --no-healthcheck --entrypoint node "$IMAGE" -e "$stub_js" > /dev/null

# 4. Traefik: the real flags (no ACME), the real dynamic files (routers.yml with its DOMAIN template, middlewares.yml with the
#    allowlist widened so the test client passes), a dummy certificate.
timage="$(jq -r '.services.traefik.image' <<< "$all")"
mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$all" | tr -d '\r' |
  grep -Ev '^--(certificatesresolvers\.|entrypoints\.websecure\.http\.tls\.(certResolver|domains))')
# The resolver and domains flags are dropped (no ACME in the test); TLS itself must stay on for the websecure entrypoint.
flags+=(--entrypoints.websecure.http.tls=true)
mkdir -p "$stage/tr/dynamic"
cp traefik/dynamic/*.yml "$stage/tr/dynamic/"
sed -i 's#- 10.0.0.0/24#- 0.0.0.0/0#' "$stage/tr/dynamic/middlewares.yml"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$stage/tr/dynamic/test-k.pem" \
  -out "$stage/tr/dynamic/test-c.pem" -days 2 -subj "/CN=*.${DOMAIN_T}" -addext "subjectAltName=DNS:*.${DOMAIN_T}" 2> /dev/null
cat > "$stage/tr/dynamic/test-cert.yml" << 'EOF'
tls:
  certificates:
    - certFile: /etc/traefik/dynamic/test-c.pem
      keyFile: /etc/traefik/dynamic/test-k.pem
EOF
cid="$(docker create --name hmtest-traefik --network "$NET_PROXY" -p 127.0.0.1::443 -e DOMAIN="$DOMAIN_T" --tmpfs /letsencrypt "$timage" "${flags[@]}")"
chmod 644 "$stage/tr/dynamic/test-k.pem"
docker cp "$stage/tr/." "$cid:/etc/traefik"
docker start "$cid" > /dev/null

echo "--- Homepage container"
healthy=0
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' hmtest-homepage 2> /dev/null)" = healthy ] && {
    healthy=1
    break
  }
  sleep 3
done
check "Homepage reports healthy (image healthcheck on 127.0.0.1 passes with HOMEPAGE_ALLOWED_HOSTS set)" test "$healthy" = 1
hx() { docker exec hmtest-homepage "$@"; }
check "process 1 and the exec user run as uid 10003, gid 10003 (not root)" test "$(hx sh -c 'id -u; id -g; awk "/^Uid:/{print \$2}" /proc/1/status')" = "$(printf '10003\n10003\n10003')"
check "root file system is read-only (cannot write to /app or /etc)" bash -c '! docker exec hmtest-homepage sh -c "touch /app/x 2>/dev/null || touch /etc/x 2>/dev/null"'
check "the config mount is read-only (cannot write config or create logs there)" bash -c '! docker exec hmtest-homepage sh -c "touch /app/config/x 2>/dev/null || mkdir /app/config/logs 2>/dev/null"'
check "only the tmpfs paths are writable (/tmp)" bash -c 'docker exec hmtest-homepage sh -c "touch /tmp/x && touch /app/.next/cache/x"'
check "docker inspect: ReadonlyRootfs, CapDrop ALL, no published ports (no port bindings)" test "$(docker inspect hmtest-homepage -f '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}} {{len .HostConfig.PortBindings}}')" = 'true ["ALL"] 0'
check "docker inspect: no mount of docker.sock (the only mount is the config)" test "$(docker inspect hmtest-homepage -f '{{range .Mounts}}{{.Destination}} {{end}}')" = "/app/config "
check "no log file is written into the config directory (logs go to stdout)" bash -c '! docker exec hmtest-homepage sh -c "ls /app/config/logs" 2>/dev/null'
check "Homepage logged no filesystem error (EROFS, EACCES, ENOENT, EPERM) while booting and rendering" bash -c '! docker logs hmtest-homepage 2>&1 | grep -Eq "EROFS|EACCES|EPERM|ENOENT"'

hp_get() { # hp_get <host header> <path>: body on stdout, from inside the container (direct, bypassing Traefik)
  docker exec hmtest-homepage wget -qO- --header "Host: $1" "http://127.0.0.1:3000$2" 2> /dev/null
}
hp_code() { # hp_code <host header> <path>
  docker exec hmtest-homepage wget -S -qO /dev/null --header "Host: $1" "http://127.0.0.1:3000$2" 2>&1 | awk '/^ *HTTP\//{c=$2} END{print c}'
}
echo "--- rendering and host check"
check "renders with the dummy domain: /api/services has every tile with https://<sub>.${DOMAIN_T}/" bash -c '
  b="$(docker exec hmtest-homepage wget -qO- --header "Host: dashboard.'"$DOMAIN_T"'" http://127.0.0.1:3000/api/services)"
  for h in traefik auth ha tools links netdata pihole portainer; do grep -q "https://$h.'"$DOMAIN_T"'/" <<< "$b" || exit 1; done
  ! grep -q "HOMEPAGE_VAR_DOMAIN" <<< "$b"'
check "the page itself renders (HTTP 200, title from settings.yaml)" bash -c '[ "$(docker exec hmtest-homepage wget -qO- --header "Host: dashboard.'"$DOMAIN_T"'" http://127.0.0.1:3000/ | grep -c "Home lab</title>")" -ge 1 ]'
check "HOMEPAGE_ALLOWED_HOSTS: the right host is accepted (200)" test "$(hp_code "dashboard.$DOMAIN_T" /api/services)" = 200
check "HOMEPAGE_ALLOWED_HOSTS: another host is refused (400)" test "$(hp_code evil.example.test /api/services)" = 400
check "HOMEPAGE_ALLOWED_HOSTS: the apex and www hosts are refused too" test "$(hp_code "$DOMAIN_T" /api/services)$(hp_code "www.$DOMAIN_T" /api/services)" = 400400
check "HOMEPAGE_ALLOWED_HOSTS: a host that merely contains the right name is refused" test "$(hp_code "dashboard.$DOMAIN_T.evil.example.test" /api/services)" = 400

echo "--- no Docker integration"
check "Homepage is attached to the proxy network only" test "$(docker inspect hmtest-homepage -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')" = "$NET_PROXY "
check "no Docker integration: Homepage cannot reach a socket proxy (no such host, no Docker data source)" bash -c '! docker exec hmtest-homepage wget -qO /dev/null -T 3 http://socket-proxy:2375/containers/json 2>/dev/null'
check "tiles render with no server or container reference (plain links)" bash -c 'b="$(docker exec hmtest-homepage wget -qO- --header "Host: dashboard.'"$DOMAIN_T"'" http://127.0.0.1:3000/api/services)"; ! grep -q "\"container\"" <<< "$b"'
check "Homepage logged no Docker error" bash -c '! docker logs hmtest-homepage 2>&1 | grep -Ei "docker|socket-proxy"'

echo "--- through Traefik (real flags, routers and middlewares; stub outpost)"
tip="$(docker inspect "$cid" -f "{{(index .NetworkSettings.Networks \"$NET_PROXY\").IPAddress}}")"
: "$tip"
hostport="$(docker port "$cid" 443/tcp | head -n 1 | sed 's/.*://')"
via() { # via <host> <path> [curl args]: prints "<code> <Location header>"; no redirects followed
  local h="$1" p="$2"
  shift 2
  curl -sk -o /dev/null -D - -w 'CODE %{http_code}
' --connect-to "$h:443:127.0.0.1:${hostport}" "$@" "https://$h$p" 2> /dev/null |
    tr -d '\r' | awk '/^CODE /{c=$2} tolower($1)=="location:"{l=$2} END{print (c == "" ? "000" : c), l}' || true
}
viab() { # body
  local h="$1" p="$2"
  shift 2
  curl -sk --connect-to "$h:443:127.0.0.1:${hostport}" "$@" "https://$h$p" || true
}
ready=0
for _ in $(seq 1 30); do
  case "$(via "dashboard.$DOMAIN_T" /)" in 302*) ready=1 && break ;; esac
  sleep 2
done
check "Traefik discovered the Homepage routers (anonymous request answered with 302)" test "$ready" = 1
check "Traefik reports no error for the homepage routers or the authentik middleware" bash -c '! docker logs "$1" 2>&1 | jq -R -r "fromjson? | select(.level==\"error\") | .msg" | grep -Ei "homepage|authentik|outpost|forwardauth|middleware"' _ "$cid"
r="$(via "dashboard.$DOMAIN_T" /)"
check "anonymous request: 302 to the Authentik authorize endpoint (forward auth, Homepage not reached) [$r]" bash -c '[[ "$1" == "302 https://auth.lab.example.test/application/o/authorize/"* ]]' _ "$r"
check "anonymous request returns no Homepage content (no title, no tiles)" bash -c '! curl -sk --connect-to "dashboard.'"$DOMAIN_T"':443:127.0.0.1:'"$hostport"'" https://dashboard.'"$DOMAIN_T"'/ | grep -Eq "Home lab|Traefik"'
r="$(via "dashboard.$DOMAIN_T" /api/services)"
check "anonymous API request (tile data) is also 302, no data [$r]" bash -c '[[ "$1" == 302* ]] && ! curl -sk --connect-to "dashboard.'"$DOMAIN_T"':443:127.0.0.1:'"$hostport"'" https://dashboard.'"$DOMAIN_T"'/api/services | grep -q "tiles\|Traefik"' _ "$r"
check "a forged identity header does not bypass forward auth (still 302)" bash -c '[[ "$1" == 302* ]]' _ "$(via "dashboard.$DOMAIN_T" / -H 'X-authentik-username: akadmin' -H 'X-authentik-groups: homelab-admins')"
check "with an accepted session (stub says 200) Homepage serves the page through Traefik" bash -c 'viab() { curl -sk --connect-to "dashboard.'"$DOMAIN_T"':443:127.0.0.1:'"$hostport"'" "$@"; }; viab -H "Cookie: stub_session=ok" https://dashboard.'"$DOMAIN_T"'/ | grep -q "Home lab</title>"'
check "with an accepted session the tile data is served and carries the dummy domain" bash -c 'curl -sk --connect-to "dashboard.'"$DOMAIN_T"':443:127.0.0.1:'"$hostport"'" -H "Cookie: stub_session=ok" https://dashboard.'"$DOMAIN_T"'/api/services | grep -q "https://traefik.'"$DOMAIN_T"'/"'
for _ in $(seq 1 20); do # the outpost router appears once Traefik has also seen the authentik service
  [ "$(viab "dashboard.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB ] && break
  sleep 2
done
check "outpost callback path on the app host goes to the outpost, not to Homepage and not into a login loop" test "$(viab "dashboard.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB
check "security headers are on the response (HSTS, nosniff, frame deny)" bash -c 'h="$(curl -skI --connect-to "dashboard.'"$DOMAIN_T"':443:127.0.0.1:'"$hostport"'" -H "Cookie: stub_session=ok" https://dashboard.'"$DOMAIN_T"'/)"; grep -qi "^strict-transport-security: max-age=" <<< "$h" && grep -qi "^x-content-type-options: nosniff" <<< "$h" && grep -qi "^x-frame-options: deny" <<< "$h"'
# The wildcard certificate has no apex name, so the strict-SNI TLS options refuse the handshake (000) before any router is asked.
check "the apex is NOT served (404 or refused at TLS), even with an accepted session" bash -c 'c="$(cut -d" " -f1 <<< "$1")"; [ "$c" = 404 ] || [ "$c" = 000 ]' _ "$(via "$DOMAIN_T" / -H 'Cookie: stub_session=ok')"
check "www is NOT served (404), even with an accepted session" test "$(via "www.$DOMAIN_T" / -H 'Cookie: stub_session=ok' | cut -d' ' -f1)" = 404
check "an unknown host is NOT served by Homepage (404)" test "$(via "unknown.$DOMAIN_T" / -H 'Cookie: stub_session=ok' | cut -d' ' -f1)" = 404
docker stop hmtest-auth > /dev/null
code="$(via "dashboard.$DOMAIN_T" / -H 'Cookie: stub_session=ok' | cut -d' ' -f1)"
check "Authentik down: Homepage is NOT served (forward auth fails closed: got $code)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$code"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Homepage checks passed\n'
