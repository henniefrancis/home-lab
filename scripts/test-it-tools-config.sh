#!/usr/bin/env bash
# test-it-tools-config.sh - self-test of the IT Tools stack (R17, milestone M7). Needs docker (Compose v2.24+), jq, curl, openssl.
#
# Usage: scripts/test-it-tools-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no build, no containers)
#   (default)  also builds the image and boots a throw-away copy of the path (CI runs this; under a minute on a runner)
#
# Dummy values only: a fake domain (lab.example.test), a self-signed wildcard certificate, a stub in place of the Authentik
# outpost (our own NGINX image with a test config, so no extra image is pulled). Nothing is sent to ACME, AWS or any real host.
# Everything it creates is named ittest-* and removed on exit.
#
# Static: both Dockerfile FROM lines pinned by digest and nothing downloaded at build (N8), the image tag matches the upstream
#   release, dedicated uid 10005 (not root, not 1000), read-only root with one small tmpfs, cap_drop ALL, no-new-privileges,
#   memory and pid limits, no published port, proxy network only, no docker.sock, no secret, the routers (allowlist then
#   authentik, outpost router), the Authentik provider/application/binding and the outpost list, the Homepage tile, Dependabot.
# Full run: the image builds; NGINX runs as 10005 with a read-only root; the site and a deep link are served; the CSP and
#   server_tokens are in place; dot files are refused; through the REAL Traefik flags, routers and middlewares an anonymous
#   request gets the login redirect, an accepted session gets the app with the security headers, the outpost callback goes to
#   the outpost, and Authentik down fails closed.
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
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: keep "container:/path" arguments intact
# Hermetic: the shell environment would win over --env-file, so drop anything that lab.env defines.
unset PROXY_SUBNET AUTHENTIK_AUTH_SUBNET APPS_ROOT DOMAIN AUTHENTIK_UID AUTHENTIK_GID AUTHENTIK_PG_UID AUTHENTIK_PG_GID HOMEPAGE_UID HOMEPAGE_GID TRAEFIK_UID TRAEFIK_GID ITTOOLS_UID ITTOOLS_GID TZ

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
NET_PROXY=ittest-proxy
TEST_IMAGE=home-lab/it-tools:ittest
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0 # debugging: leave the ittest-* containers and networks (remove them by hand afterwards)
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f ittest-traefik ittest-app ittest-auth > /dev/null 2>&1 || true
    docker network rm "$NET_PROXY" > /dev/null 2>&1 || true
    docker image rm "$TEST_IMAGE" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT

# Scratch directory (holds a throw-away TLS test key): ITTOOLS_TEST_TMP (for example a scratchpad) or the checkout (git-ignored).
stage="$(mktemp -d -p "${ITTOOLS_TEST_TMP:-.}" .it-tools-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })" # a path docker.exe understands under Git Bash, plain pwd elsewhere
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik"
: > "$stage/secrets/tailscale/tailscale.env"

export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f it-tools/compose.yaml --env-file config/lab.env config --format json)"
app="$(jq -c '.services["it-tools"]' <<< "$alone")"
IMAGE="$(jq -r '.image' <<< "$app")"
printf 'image: %s\n' "$IMAGE"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2; }
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
df=it-tools/Dockerfile
bp=authentik/blueprints/homelab-apps.yaml

echo "--- static: image build (it-tools/Dockerfile)"
froms="$(grep -E '^FROM ' "$df")"
check "exactly two FROM lines: the official IT Tools image and the official NGINX unprivileged image" bash -c '[ "$(wc -l <<< "$1")" = 2 ] && grep -q "^FROM ghcr.io/corentinth/it-tools:" <<< "$1" && grep -q "^FROM nginxinc/nginx-unprivileged:[0-9.]*-alpine-slim@" <<< "$1"' _ "$froms"
check "both FROM lines pinned tag@sha256 (N8)" bash -c '! grep -Ev "@sha256:[0-9a-f]{64}( AS [a-z]+)?$" <<< "$1"' _ "$froms"
check "nothing is installed or downloaded at build time (no RUN, no ADD, N8)" bash -c '! grep -Eq "^(RUN|ADD) " "$1"' _ "$df"
check "only the static site and our nginx.conf are copied in, root-owned" bash -c '[ "$(grep -c "^COPY " "$1")" = 2 ] && grep -q "^COPY --from=app --chown=0:0 .* /usr/share/nginx/html /usr/share/nginx/html$" "$1" && grep -q "^COPY --chown=0:0 .* nginx.conf /etc/nginx/conf.d/default.conf$" "$1"' _ "$df"
check "NGINX starts directly (ENTRYPOINT nginx -g 'daemon off;'): no entrypoint script rewrites the committed config" grep -qx 'ENTRYPOINT \["nginx", "-g", "daemon off;"\]' "$df"
up_tag="$(sed -nE 's#^FROM ghcr.io/corentinth/it-tools:([^@]+)@.*#\1#p' "$df")"
check "the image tag names the upstream release it contains (home-lab/it-tools:$up_tag)" test "$IMAGE" = "home-lab/it-tools:$up_tag"
check "the compose service builds from it-tools/ (local image, nothing pulled under that name)" test "$(jq -r '.build.context | gsub("\\\\"; "/") | split("/") | last' <<< "$app")" = it-tools

echo "--- static: container definition"
check "root compose includes it-tools, and --only it-tools renders the same service" test "$(jq -r '.services["it-tools"].image' <<< "$all")" = "$IMAGE"
check "runs as ITTOOLS_UID:ITTOOLS_GID = 10005:10005 (not root, not the login user 1000)" test "$(jq -r '.user' <<< "$app")" = "10005:10005" -a "$(lab_get ITTOOLS_UID):$(lab_get ITTOOLS_GID)" = "10005:10005"
check "the uid is not used by any other service in lab.env" test "$(grep -cE '^[A-Z_]+_UID=10005$' config/lab.env)" = 1
check "read-only root file system; the only tmpfs is /tmp (16m), owned by the service uid" test "$(jq -c '[.read_only, .tmpfs]' <<< "$app")" = '[true,["/tmp:uid=10005,gid=10005,mode=0700,size=16m"]]'
check "cap_drop ALL, no cap_add, not privileged, no-new-privileges" test "$(jq -c '[.cap_drop, (.cap_add // []), (.privileged // false), (.security_opt | index("no-new-privileges:true") != null)]' <<< "$app")" = '[["ALL"],[],false,true]'
check "memory limit 64M and pid limit 64" test "$(jq -c '[.mem_limit, .pids_limit]' <<< "$app")" = '["67108864",64]'
check "no published ports (reached through Traefik only)" test "$(jq '.ports // [] | length' <<< "$app")" = 0
check "no volumes at all (no data, no docker.sock), no DOCKER_HOST" test "$(jq -c '[(.volumes // [] | length), (.environment.DOCKER_HOST // "none")]' <<< "$app")" = '[0,"none"]'
check "no secret and no environment of its own (nothing to leak)" test "$(jq '.environment // {} | length' <<< "$app")" = 0
check "on the proxy network ONLY (external)" test "$(jq -c '[.networks | keys[]]' <<< "$app")" = '["proxy"]' -a "$(jq -r '.networks.proxy.external' <<< "$alone")" = true
check "healthcheck on 127.0.0.1:8080 inside the container" bash -c 'jq -r ".healthcheck.test | join(\" \")" <<< "$1" | grep -q "http://127.0.0.1:8080/"' _ "$app"
check "log rotation json-file 10m x 3" test "$(jq -c '[.logging.driver, .logging.options["max-size"], .logging.options["max-file"]]' <<< "$app")" = '["json-file","10m","3"]'
check "no Traefik labels (routers are files, SEC-H2)" test "$(jq '.labels // {} | length' <<< "$app")" = 0
nc=it-tools/nginx.conf
check "nginx.conf: listens on 8080 only, server_tokens off, SPA fallback to index.html, dot files refused" bash -c 'grep -q "^    listen 8080;$" "$1" && [ "$(grep -c "listen " "$1")" = 1 ] && grep -q "server_tokens off;" "$1" && grep -q "try_files \$uri \$uri/ /index.html;" "$1" && grep -q "location ~ /\\\\. {" "$1"' _ "$nc"
check "nginx.conf: CSP limits outbound calls to this host (connect-src 'self') and forbids framing" bash -c 'grep -q "Content-Security-Policy \"connect-src '"'"'self'"'"';.*frame-ancestors '"'"'none'"'"'\" always;" "$1"' _ "$nc"

echo "--- static: routers, Authentik, Homepage, Dependabot"
check "it-tools router: tools.<domain> through the DOMAIN template, websecure, lan-allowlist then authentik, service it-tools" bash -c 'b="$(router_block it-tools)"; grep -q "Host(\`tools.{{ env \"DOMAIN\" }}\`)" <<< "$b" && grep -q "websecure" <<< "$b" && grep -q "service: it-tools$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 2 ] && grep -A1 "middlewares:" <<< "$b" | grep -q -- "- lan-allowlist" && grep -q -- "- authentik$" <<< "$b"' _
check "it-tools service points at http://it-tools:8080" bash -c 'awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://it-tools:8080"' _ $rt
check "it-tools-outpost router has the same shape as the Traefik dashboard's outpost router" bash -c 'diff <(router_block dashboard-outpost | grep -Ev "rule:|^ *#|^$") <(router_block it-tools-outpost | grep -Ev "rule:|^ *#|^$") && router_block it-tools-outpost | grep -q "tools.{{ env"' _
check "blueprint: forward_single provider homelab-it-tools for https://tools.<domain>, application it-tools" bash -c 'grep -q "name: homelab-it-tools" "$1" && grep -q "slug: it-tools" "$1" && grep -q "external_host: !Format \[\"https://tools.%s\", !Env DOMAIN\]" "$1"' _ $bp
check "blueprint: the application is bound to homelab-admins (fail closed) and the outpost serves the provider" bash -c 'awk "/target: !KeyOf app-it-tools/{f=1} f&&/group:/{print; exit}" "$1" | grep -q "group-admins" && awk "/managed: goauthentik.io\/outposts\/embedded/{f=1} f" "$1" | grep -q -- "- !KeyOf provider-it-tools"' _ $bp
check "Homepage: the IT Tools tile is live (Tools group), not in Coming soon" bash -c 'f=homepage/config/services.yaml; awk "/^- Tools:/{f=1;next} /^- /{f=0} f" $f | grep -q "href: https://tools.{{HOMEPAGE_VAR_DOMAIN}}/" && ! awk "/^- Coming soon:/{f=1} f" $f | grep -q "tools\."'
check "Dependabot: docker ecosystem on /it-tools (both FROM digests) and the local image ignored by docker-compose" bash -c 'f=.github/dependabot.yml; grep -q "directory: /it-tools$" $f && grep -q -- "- /it-tools$" $f && grep -q "dependency-name: home-lab/it-tools" $f'

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static IT Tools checks passed (use no flag for the build and container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
# Build and containers: the REAL image and definition, the REAL Traefik flags, routers and middlewares, a stub outpost.
# --------------------------------------------------------------------------------------------------------------------
echo "--- build"
check "the image builds from it-tools/Dockerfile" docker build -q -t "$TEST_IMAGE" it-tools
docker network create "$NET_PROXY" > /dev/null

args=(--name ittest-app --network "$NET_PROXY" --network-alias it-tools --user "$(jq -r '.user' <<< "$app")" --read-only --cap-drop ALL
  --security-opt no-new-privileges:true --memory "$(jq -r '.mem_limit' <<< "$app")" --pids-limit "$(jq -r '.pids_limit' <<< "$app")"
  --health-cmd "$(jq -r '.healthcheck.test[1:] | join(" ")' <<< "$app")" --health-interval 2s --health-retries 10)
while IFS= read -r l; do args+=(--tmpfs "$l"); done < <(jq -r '.tmpfs[]' <<< "$app" | tr -d '\r')
docker run -d "${args[@]}" "$TEST_IMAGE" > /dev/null

# Stub for the Authentik embedded outpost (authentik-server:9000): our own image, a test config. Forward auth answers the login
# redirect unless the request carries the cookie stub_session=ok; any other outpost path answers OUTPOST-STUB.
cat > "$stage/stub.conf" << 'EOF'
server {
    listen 9000;
    location /outpost.goauthentik.io/auth/traefik {
        if ($http_cookie ~ "stub_session=ok") {
            add_header X-authentik-username tester;
            return 200 "ok";
        }
        return 302 https://auth.lab.example.test/application/o/authorize/?client_id=stub;
    }
    location /outpost.goauthentik.io/ {
        return 200 "OUTPOST-STUB";
    }
    location / {
        return 404;
    }
}
EOF
chmod 644 "$stage/stub.conf"
acid="$(docker create --name ittest-auth --network "$NET_PROXY" --network-alias authentik-server --no-healthcheck "$TEST_IMAGE")"
docker cp "$here/stub.conf" "$acid:/etc/nginx/conf.d/default.conf"
docker start ittest-auth > /dev/null

timage="$(jq -r '.services.traefik.image' <<< "$all")"
mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$all" | tr -d '\r' |
  grep -Ev '^--(certificatesresolvers\.|entrypoints\.websecure\.http\.tls\.(certResolver|domains))')
flags+=(--entrypoints.websecure.http.tls=true)
mkdir -p "$stage/tr/dynamic"
cp traefik/dynamic/*.yml "$stage/tr/dynamic/"
sed -i 's#- 10.0.0.0/24#- 0.0.0.0/0#' "$stage/tr/dynamic/middlewares.yml"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$here/tr/dynamic/test-k.pem" \
  -out "$here/tr/dynamic/test-c.pem" -days 2 -subj "/CN=*.${DOMAIN_T}" -addext "subjectAltName=DNS:*.${DOMAIN_T}" 2> /dev/null
cat > "$stage/tr/dynamic/test-cert.yml" << 'EOF'
tls:
  certificates:
    - certFile: /etc/traefik/dynamic/test-c.pem
      keyFile: /etc/traefik/dynamic/test-k.pem
EOF
cid="$(docker create --name ittest-traefik --network "$NET_PROXY" -p 127.0.0.1::443 -e DOMAIN="$DOMAIN_T" --tmpfs /letsencrypt "$timage" "${flags[@]}")"
chmod 644 "$stage/tr/dynamic/test-k.pem"
docker cp "$here/tr/." "$cid:/etc/traefik"
docker start "$cid" > /dev/null

echo "--- IT Tools container"
healthy=0
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' ittest-app 2> /dev/null)" = healthy ] && {
    healthy=1
    break
  }
  sleep 2
done
check "the container reports healthy (the compose healthcheck command)" test "$healthy" = 1
ax() { docker exec ittest-app "$@"; }
check "NGINX master and workers run as uid 10005 (not root, not 101, not 1000)" bash -c '[ "$(docker exec ittest-app sh -c "for p in /proc/[0-9]*/status; do awk \"/^Uid:/{print \\\$2}\" \$p; done" | sort -u)" = 10005 ]'
check "root file system is read-only (cannot write the site or /etc)" bash -c '! docker exec ittest-app sh -c "touch /usr/share/nginx/html/x 2>/dev/null || touch /etc/x 2>/dev/null"'
check "the site files are root-owned (the service uid cannot change them)" test "$(ax sh -c 'find /usr/share/nginx/html ! -user 0 | wc -l')" = 0
check "docker inspect: ReadonlyRootfs, CapDrop ALL, no port bindings, no mounts" test "$(docker inspect ittest-app -f '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}} {{len .HostConfig.PortBindings}} {{len .Mounts}}')" = 'true ["ALL"] 0 0'
code() { ax wget -S -q -O /dev/null "http://127.0.0.1:8080$1" 2>&1 | awk '/^ *HTTP\//{c=$2} END{print c}'; }
check "the app is served (200, IT Tools in the page)" bash -c '[ "$(docker exec ittest-app wget -qO- http://127.0.0.1:8080/ | grep -c "IT Tools")" -ge 1 ]'
check "a deep link to a tool is answered with the app (SPA fallback, 200)" bash -c 'docker exec ittest-app wget -qO- http://127.0.0.1:8080/base64-string-converter | grep -q "IT Tools"'
check "a dot file is refused (404)" test "$(code /.git/config)" = 404
hdr="$(ax wget -S -q -O /dev/null http://127.0.0.1:8080/ 2>&1)"
check "the CSP header is sent and the NGINX version is hidden" bash -c 'grep -qi "Content-Security-Policy: connect-src '"'"'self'"'"'" <<< "$1" && grep -qi "^ *Server: nginx$" <<< "$1"' _ "$hdr"
check "NGINX logged nothing at warn level or worse, and no entrypoint script ran" bash -c 'l="$(docker logs ittest-app 2>&1)"; ! grep -Eiq "\[(warn|error|crit|alert|emerg)\]|permission denied|read-only file system|docker-entrypoint" <<< "$l"'

echo "--- through Traefik (real flags, routers and middlewares; stub outpost)"
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
  case "$(via "tools.$DOMAIN_T" /)" in 302*) ready=1 && break ;; esac
  sleep 2
done
check "Traefik discovered the IT Tools routers (anonymous request answered with 302)" test "$ready" = 1
check "Traefik reports no error for the it-tools routers or the authentik middleware" bash -c '! docker logs "$1" 2>&1 | jq -R -r "fromjson? | select(.level==\"error\") | .msg" | grep -Ei "it-tools|authentik|outpost|forwardauth|middleware"' _ "$cid"
r="$(via "tools.$DOMAIN_T" /)"
check "anonymous request: 302 to the Authentik authorize endpoint (IT Tools not reached) [$r]" bash -c '[[ "$1" == "302 https://auth.lab.example.test/application/o/authorize/"* ]]' _ "$r"
check "anonymous request returns no IT Tools content" bash -c '! grep -q "IT Tools" <<< "$1"' _ "$(viab "tools.$DOMAIN_T" /)"
check "a forged identity header does not bypass forward auth (still 302)" bash -c '[[ "$1" == 302* ]]' _ "$(via "tools.$DOMAIN_T" / -H 'X-authentik-username: akadmin' -H 'X-authentik-groups: homelab-admins')"
check "with an accepted session (stub says 200) IT Tools is served through Traefik" bash -c 'grep -q "IT Tools" <<< "$1"' _ "$(viab "tools.$DOMAIN_T" / -H 'Cookie: stub_session=ok')"
h="$(curl -skI --connect-to "tools.$DOMAIN_T:443:127.0.0.1:${hostport}" -H 'Cookie: stub_session=ok' "https://tools.$DOMAIN_T/" | tr -d '\r')"
check "the shared security headers are on the response (HSTS, nosniff, frame deny) and the app's CSP passes through" bash -c 'grep -qi "^strict-transport-security: max-age=" <<< "$1" && grep -qi "^x-content-type-options: nosniff" <<< "$1" && grep -qi "^x-frame-options: deny" <<< "$1" && grep -qi "^content-security-policy: connect-src" <<< "$1"' _ "$h"
check "the Server header is removed by Traefik (no NGINX banner reaches the browser)" bash -c '! grep -qi "^server: nginx" <<< "$1"' _ "$h"
for _ in $(seq 1 20); do
  [ "$(viab "tools.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB ] && break
  sleep 2
done
check "outpost callback path on the app host goes to the outpost, not to IT Tools" test "$(viab "tools.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB
check "www and an unknown host are NOT served (404), even with an accepted session" test "$(via "www.$DOMAIN_T" / -H 'Cookie: stub_session=ok' | cut -d' ' -f1)$(via "unknown.$DOMAIN_T" / -H 'Cookie: stub_session=ok' | cut -d' ' -f1)" = 404404
docker stop ittest-auth > /dev/null
c="$(via "tools.$DOMAIN_T" / -H 'Cookie: stub_session=ok' | cut -d' ' -f1)"
check "Authentik down: IT Tools is NOT served (forward auth fails closed: got $c)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$c"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll IT Tools checks passed\n'
