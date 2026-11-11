#!/usr/bin/env bash
# test-koffan-config.sh - self-test of the Koffan stack (R19, milestone M14). Needs docker (Compose v2.24+), jq, curl, openssl.
#
# Usage: scripts/test-koffan-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also boots the real image and the real Traefik routers (CI runs this)
#
# Dummy values only: a fake domain (lab.example.test), a self-signed wildcard certificate and a stub in place of authentik-server
# (scripts/lib/app-test.sh). Nothing is sent to AWS or any real host. Everything it creates is named kftest-* and removed on exit. A named
# volume (volume-nocopy, so Docker does not copy the image's root-owned /data over the ownership the test sets) holds the data.
#
# Static: pinned image; uid 10008 (never root or 1000, unique in lab.env); read-only root, cap_drop ALL, no-new-privileges, limits; no
#   secret and no API_TOKEN, WEBHOOK_URL or MULTI_USER; DISABLE_AUTH; only the proxy network, no published port, no socket; the three
#   routers (forward auth, outpost, the exact static PWA paths with the allowlist only); the Authentik provider, application and the two
#   group bindings and the outpost list; Homepage tile, Pi-hole record, bootstrap, preflight, backup job, Dependabot.
# Full run: healthy with the image's own check; one process, uid 10008, no capability, no_new_privs; read-only root, writable /data; a list is
#   written through Traefik and survives a restart; anonymous requests to / and to the data and API paths are redirected to the outpost
#   while exactly the PWA files (the manifest, the icons, the service worker) are served without a login; every file the page and the
#   manifest reference is on that list and nothing on the list is dead; look-alike and traversal paths do not bypass; Authentik down
#   fails the app closed.
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
unset PROXY_SUBNET AUTHENTIK_AUTH_SUBNET OIDC_SUBNET APPS_ROOT DOMAIN AUTHENTIK_UID AUTHENTIK_GID AUTHENTIK_PG_UID AUTHENTIK_PG_GID HOMEPAGE_UID HOMEPAGE_GID TRAEFIK_UID TRAEFIK_GID ITTOOLS_UID ITTOOLS_GID PIHOLE_UID PIHOLE_GID PIHOLE_UPSTREAMS PI_LAN_IP LINKWARDEN_UID LINKWARDEN_GID KOFFAN_UID KOFFAN_GID SPEEDTEST_UID SPEEDTEST_GID N8N_UID N8N_GID COUCHDB_UID COUCHDB_GID SPEEDTEST_SCHEDULE SPEEDTEST_SERVERS COUCHDB_SYNC_USER COUCHDB_SYNC_DB TZ
# shellcheck source=lib/app-test.sh
. scripts/lib/app-test.sh

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
NET=kftest-proxy
VOL=kftest-data
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f kftest-app kftest-traefik kftest-auth > /dev/null 2>&1 || true
    docker network rm "$NET" > /dev/null 2>&1 || true
    docker volume rm "$VOL" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap "exit 130" INT TERM

stage="$(mktemp -d -p "${KOFFAN_TEST_TMP:-.}" .koffan-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })"
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole" "$stage/secrets/linkwarden" \
  "$stage/secrets/portainer" "$stage/secrets/n8n" "$stage/secrets/couchdb" "$stage/secrets/speedtest"
: > "$stage/secrets/tailscale/tailscale.env"
export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f koffan/compose.yaml --env-file config/lab.env config --format json)"
kf="$(jq -c '.services.koffan' <<< "$alone")"
IMG="$(jq -r '.image' <<< "$kf")"
printf 'image: %s\n' "$IMG"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2-; }
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z0-9-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
bp=authentik/blueprints/homelab-apps.yaml
pwa_paths() { router_block koffan-pwa | tr '\n' ' ' | grep -oE 'Path\(`[^`]+`\)' | sed -E 's/^Path\(`(.*)`\)$/\1/' | sort; }

echo "--- static: image, identity, hardening"
check "Koffan is a pinned ghcr.io/pansalut/koffan vX.Y.Z by digest" bash -c '[[ "$1" =~ ^ghcr\.io/pansalut/koffan:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMG"
check "root compose includes koffan with the same image" test "$(jq -r '.services.koffan.image' <<< "$all")" = "$IMG"
check "runs as KOFFAN_UID:GID 10008 (never root, never 1000); the uid is used once in lab.env" bash -c '[ "$(jq -r .user <<< "$1")" = "10008:10008" ] && [ "$(grep -cE "^[A-Z0-9_]+_UID=10008$" config/lab.env)" = 1 ] && [ "$(grep -E "^KOFFAN_UID=" config/lab.env | cut -d= -f2)" = 10008 ]' _ "$kf"
check "read-only root, cap_drop ALL, no cap_add, not privileged, no-new-privileges, memory 128m, pids limit" test "$(jq -c '[.read_only, .cap_drop, (.cap_add // []), (.privileged // false), (.security_opt | index("no-new-privileges:true") != null), .mem_limit, (.pids_limit != null)]' <<< "$kf")" = '[true,["ALL"],[],false,true,"134217728",true]'
check "no published port, no docker.sock, no Traefik labels, no secrets, only the proxy network" bash -c '[ "$(jq ".ports // [] | length" <<< "$1")" = 0 ] && ! grep -q docker.sock <<< "$1" && [ "$(jq ".labels // {} | length" <<< "$1")" = 0 ] && [ "$(jq ".secrets // [] | length" <<< "$1")" = 0 ] && [ "$(jq -c "[.networks | keys[]]" <<< "$1")" = "[\"proxy\"]" ]' _ "$kf"
check "environment: production, DISABLE_AUTH true (Authentik is the only door), the database in /data" test "$(jq -r '[.environment.APP_ENV, .environment.DISABLE_AUTH, .environment.DB_PATH] | join(" ")' <<< "$kf")" = "production true /data/shopping.db"
check "API_TOKEN, WEBHOOK_URL, MULTI_USER and any password are NOT set (no API, no outbound webhooks, one shared list)" bash -c '! jq -r ".environment | keys[]" <<< "$1" | grep -Eqx "API_TOKEN|WEBHOOK_URL|MULTI_USER|ADMIN_USER|ADMIN_PASS|APP_PASSWORD|PASSWORD|API_WORKSPACE_ID"' _ "$kf"
check "the only writable places are the data directory (bind mount) and a tmpfs /tmp" test "$(jq -c '[[.volumes[] | [.source, .target]], .tmpfs]' <<< "$kf" | sed "s#$here#APPS#")" = '[[["APPS/koffan/data","/data"]],["/tmp:uid=10008,gid=10008,mode=0700"]]'

echo "--- static: routers, Authentik, tile, record, backup"
check "koffan router: allowlist then Authentik forward auth, priority 10, service koffan:8080" bash -c 'b="$(router_block koffan)"; grep -q "Host(\`shopping.{{ env \"DOMAIN\" }}\`)" <<< "$b" && grep -q "priority: 10$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -- "- " | tr -d " \n")" = "-lan-allowlist-authentik" ] && grep -q "service: koffan$" <<< "$b" && awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://koffan:8080"' _ $rt
check "koffan-outpost: the outpost path on the app host, priority 100, allowlist only, service authentik" bash -c 'b="$(router_block koffan-outpost)"; grep -q "PathPrefix(\`/outpost.goauthentik.io/\`)" <<< "$b" && grep -q "priority: 100$" <<< "$b" && grep -q "service: authentik$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 1 ]' _
check "koffan-pwa: priority 50, the allowlist ONLY, service koffan, and the rule uses exact Path() matches only (no PathPrefix, no regex, no wildcard)" bash -c 'b="$(router_block koffan-pwa)"; grep -q "priority: 50$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 1 ] && grep -q -- "- lan-allowlist$" <<< "$b" && ! grep -q authentik <<< "$(grep -A4 "middlewares:" <<< "$b")" && grep -q "service: koffan$" <<< "$b" && ! grep -qE "PathPrefix|PathRegexp|HostRegexp|\*" <<< "$b"' _
check "koffan-pwa lists only static, non-data files: /static/ plus manifest.json, sw.js, icon-192.png, icon-512.png, apple-touch-icon.png, favicon.ico, favicon-96.png" test "$(pwa_paths | tr '\n' ' ')" = "/static/apple-touch-icon.png /static/favicon-96.png /static/favicon.ico /static/icon-192.png /static/icon-512.png /static/manifest.json /static/sw.js "
check "blueprint: provider homelab-koffan, forward_single, shopping.<domain>, 12-hour token; application slug koffan 'Shopping list'" bash -c 'b="$(awk "/id: provider-koffan/{f=1} f&&/id: app-koffan/{exit} f" "$1")"; grep -q "mode: forward_single" <<< "$b" && grep -q "external_host: !Format \[\"https://shopping.%s\", !Env DOMAIN\]" <<< "$b" && grep -q "access_token_validity: hours=12" <<< "$b" && ! grep -q cookie_domain <<< "$b" && grep -q "slug: koffan$" "$1" && grep -q "name: Shopping list$" "$1"' _ $bp
check "blueprint: the application is bound to homelab-admins (order 0) and homelab-users (order 1), no one else, and the provider is on the embedded outpost" bash -c '[ "$(awk "/target: !KeyOf app-koffan/{getline; print}" "$1" | sort | tr -d " " | tr "\n" " ")" = "group:!KeyOfgroup-admins group:!KeyOfgroup-users " ] && awk "/id: embedded-outpost/{f=1} f" "$1" | grep -q -- "- !KeyOf provider-koffan"' _ $bp
check "Homepage: the Shopping list tile is live in the Household group (mdi-cart), and the layout lists the group" bash -c 'awk "/^- Household:/{f=1;next} /^- /{f=0} f" homepage/config/services.yaml | grep -q "href: https://shopping.{{HOMEPAGE_VAR_DOMAIN}}/" && grep -q "^  Household:" homepage/config/settings.yaml'
check "Pi-hole: shopping.<domain> is answered with the Pi's LAN address" test "$(jq -r '.services.pihole.environment.FTLCONF_dns_hosts' <<< "$all" | tr ' ' '\n' | grep -cx "shopping.$DOMAIN_T")" = 1
check "bootstrap.sh creates koffan/data for KOFFAN_UID (0700) and preflight.sh checks it" bash -c 'grep -q "install -d -m 0700 -o \"\$KF_UID\" -g \"\$KF_GID\" \"\$APPS_ROOT/koffan/data\"" scripts/bootstrap.sh && grep -q "koffan:KOFFAN:data" scripts/preflight.sh'
check "backup-apps.sh has the koffan-db sqlite job (the database is copied with sqlite3, not tarred)" bash -c 'grep -q "\"koffan-db|sqlite|koffan|data/shopping.db|\"" scripts/backup-apps.sh'
check "Dependabot watches /koffan" grep -q -- '- /koffan$' .github/dependabot.yml
check "the CI socket guard and digest pinning cover koffan/compose.yaml" bash -c 'grep -q "no_sock=.*koffan" .github/workflows/ci.yml && grep -q "koffan/compose.yaml" .github/workflows/ci.yml'
check "scan-images.sh scans the Koffan image" bash -c 'grep -q "koffan" scripts/scan-images.sh'

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Koffan checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
echo "--- containers"
docker network create "$NET" > /dev/null
docker volume rm "$VOL" > /dev/null 2>&1 || true
docker volume create "$VOL" > /dev/null
docker run --rm --user 0 --entrypoint chown --mount "type=volume,src=$VOL,dst=/v,volume-nocopy" "$IMG" 10008:10008 /v
docker run --rm --user 0 --entrypoint chmod --mount "type=volume,src=$VOL,dst=/v,volume-nocopy" "$IMG" 0700 /v
app_test_run kftest-app "$kf" koffan "$NET" --mount "type=volume,src=$VOL,dst=/data,volume-nocopy"
app_test_stub_auth kftest "$NET"
app_test_traefik kftest "$NET"
cid="$APP_TEST_CID"

echo "--- Koffan container"
healthy=0
wait_healthy kftest-app 40 && healthy=1
check "Koffan becomes healthy with the image's own check (wget /login answers with DISABLE_AUTH)" test "$healthy" = 1
procs="$(proc_ids kftest-app)"
check "every process is uid 10008 with no capability and no_new_privs set [$(tr -d '\n' <<< "$procs")]" bash -c '[ -n "$1" ] && ! grep -vq "^10008 0000000000000000 1 $" <<< "$1"' _ "$procs"
check "the root file system is read-only (the binary and /etc cannot be written)" bash -c '! docker exec kftest-app sh -c "touch /app/x 2>/dev/null || touch /etc/x 2>/dev/null"'
check "the data directory is writable by 10008 and holds the SQLite database" bash -c 'docker exec kftest-app sh -c "touch /data/.probe && rm /data/.probe && test -s /data/shopping.db"'
check "docker inspect: ReadonlyRootfs, CapDrop ALL, no port bindings, one mount (the data volume)" test "$(docker inspect kftest-app -f '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}} {{len .HostConfig.PortBindings}} {{len .Mounts}}')" = 'true ["ALL"] 0 1'
check "the log shows no error or panic" bash -c '! docker logs kftest-app 2>&1 | grep -Eiq "panic|fatal|permission denied|read-only file system|Failed to"'

echo "--- through Traefik (real flags, routers and middlewares; stub outpost)"
ready=0
for _ in $(seq 1 30); do
  case "$(via "shopping.$DOMAIN_T" /)" in 302*) ready=1 && break ;; esac
  sleep 2
done
check "Traefik discovered the Koffan routers (an anonymous request is answered with 302)" test "$ready" = 1
check "Traefik reports no error for the koffan routers or the authentik middleware" bash -c '! docker logs "$1" 2>&1 | jq -R -r "fromjson? | select(.level==\"error\") | .msg" | grep -Ei "koffan|authentik|outpost|forwardauth|middleware"' _ "$cid"
S=(-H 'Cookie: stub_session=ok')
for p in / /login /lists /items /api/suggestions /export /import /sections /static/app.js /static/htmx.min.js /static/koffan-logo.webp; do
  r="$(via "shopping.$DOMAIN_T" "$p")"
  check "anonymous GET $p is redirected to the Authentik authorize endpoint (Koffan not reached) [$r]" bash -c '[[ "$1" == "302 https://auth.lab.example.test/application/o/authorize/"* ]]' _ "$r"
done
for m in POST PUT DELETE; do
  r="$(via "shopping.$DOMAIN_T" /items -X "$m" -d 'name=x')"
  check "anonymous $m /items is redirected to the Authentik authorize endpoint [$r]" bash -c '[[ "$1" == "302 https://auth.lab.example.test/"* ]]' _ "$r"
done
check "a forged identity header does not bypass forward auth (still 302)" bash -c '[[ "$1" == 302* ]]' _ "$(via "shopping.$DOMAIN_T" / -H 'X-authentik-username: akadmin' -H 'X-authentik-groups: homelab-admins')"
page="$(viab "shopping.$DOMAIN_T" / "${S[@]}")"
check "with an accepted session the Koffan page is served through Traefik (no login form: DISABLE_AUTH)" bash -c 'grep -q "Koffan" <<< "$1" && ! grep -qi "type=\"password\"" <<< "$1"' _ "$page"
check "anonymous requests get no Koffan content" bash -c '! grep -q "Koffan" <<< "$1"' _ "$(viab "shopping.$DOMAIN_T" /)"
h="$(viah "shopping.$DOMAIN_T" / "${S[@]}")"
check "the shared security headers are on the response (HSTS, nosniff, frame deny)" bash -c 'grep -qi "^strict-transport-security: max-age=" <<< "$1" && grep -qi "^x-content-type-options: nosniff" <<< "$1" && grep -qi "^x-frame-options: deny" <<< "$1"' _ "$h"

echo "--- the PWA files without a login"
paths="$(pwa_paths)"
for p in $paths; do
  code="$(via "shopping.$DOMAIN_T" "$p" | cut -d' ' -f1)"
  check "anonymous GET $p is served (200) by koffan-pwa, so a browser can fetch it without cookies [$code]" test "$code" = 200
done
mani="$(viab "shopping.$DOMAIN_T" /static/manifest.json)"
check "the manifest (served anonymously) is valid JSON: standalone, start_url /, and every icon it names is on the pwa list" bash -c 'jq -e ".display == \"standalone\" and .start_url == \"/\"" <<< "$1" > /dev/null && for i in $(jq -r ".icons[].src" <<< "$1" | tr -d "\r"); do grep -qxF "$i" <<< "$2" || exit 1; done' _ "$mani" "$paths"
refs="$(grep -oE '<link[^>]+rel="(manifest|icon|apple-touch-icon|shortcut icon)"[^>]*>' <<< "$page" | grep -oE 'href="[^"]+"' | sed -E 's/^href="([^"?]+).*/\1/' | sort -u)"
check "every manifest and icon link of the page is on the pwa list [$(tr '\n' ' ' <<< "$refs")]" bash -c '[ -n "$1" ] && for r in $1; do grep -qxF "$r" <<< "$2" || exit 1; done' _ "$refs" "$paths"
sw="$(grep -oE "serviceWorker.register\\('[^']+" <<< "$page" | head -1 | sed -E "s/.*'//; s#\\\\/#/#g; s/\\?.*//")"
check "the service worker the page registers ($sw) is on the pwa list" bash -c '[ -n "$1" ] && grep -qxF "$1" <<< "$2"' _ "$sw" "$paths"
check "the PWA responses carry the shared security headers and no Koffan data (static files only)" bash -c 'h="$1"; grep -qi "^strict-transport-security: max-age=" <<< "$h" && ! grep -qi "set-cookie" <<< "$h"' _ "$(viah "shopping.$DOMAIN_T" /static/manifest.json)"
for p in /static/manifest.json/ /static/manifest.json.bak /static/manifest.jsonx /static/sw.jsx /static/icon-192.png/ /static/Manifest.json /static/icon-1920.png /static/app.js /static/manifest.json%2f..%2fapp.js; do
  r="$(via "shopping.$DOMAIN_T" "$p")"
  check "look-alike $p does NOT bypass forward auth [$r]" bash -c '[[ "$1" == 302* ]] || [ "${1%% *}" = 404 ] || [ "${1%% *}" = 400 ]' _ "$r"
done
r="$(via "shopping.$DOMAIN_T" /static/icon-192.png/../../items --path-as-is)"
check "a path-traversal request from a pwa path into the app is not served anonymously [$r]" bash -c '[ "${1%% *}" != 200 ]' _ "$r"
r="$(via "shopping.$DOMAIN_T" "/static/manifest.json?x=/items")"
r2="$(via "shopping.$DOMAIN_T" "/items?x=/static/manifest.json")"
check "a query string does not change the match: the manifest is still served [$r], and /items?x=/static/manifest.json still redirects [$r2]" bash -c '[ "${1%% *}" = 200 ] && [[ "$2" == 302* ]]' _ "$r" "$r2"
r="$(via "shopping.$DOMAIN_T" //static/manifest.json)"
check "a doubled slash is normalised by Traefik to the very same static file (served 200, the same manifest body), not to anything else [$r]" bash -c '[ "${1%% *}" = 200 ] && [ "$2" = "$3" ]' _ "$r" "$(viab "shopping.$DOMAIN_T" //static/manifest.json)" "$mani"
check "the outpost callback path on the app host goes to the outpost, not to Koffan" test "$(viab "shopping.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB
check "www and an unknown host are NOT served (404), even with an accepted session" test "$(via "www.$DOMAIN_T" / "${S[@]}" | cut -d' ' -f1)$(via "unknown.$DOMAIN_T" / "${S[@]}" | cut -d' ' -f1)" = 404404

echo "--- data survives a restart"
c="$(curl -sk -o /dev/null -w '%{http_code}' -X POST --connect-to "shopping.$DOMAIN_T:443:127.0.0.1:$APP_TEST_HOSTPORT" "${S[@]}" -d 'name=ZzPersistTestList&icon=x' "https://shopping.$DOMAIN_T/lists" || true)"
check "a shopping list is created through Traefik with an accepted session (200) [$c]" test "$c" = 200
check "the list is in the page" bash -c 'grep -q ZzPersistTestList <<< "$1"' _ "$(viab "shopping.$DOMAIN_T" / "${S[@]}")"
docker restart kftest-app > /dev/null
wait_healthy kftest-app 40 || true
for _ in $(seq 1 20); do
  grep -q ZzPersistTestList <<< "$(viab "shopping.$DOMAIN_T" / "${S[@]}")" && break
  sleep 2
done
check "after a container restart the list is still there (SQLite in the data volume)" bash -c 'grep -q ZzPersistTestList <<< "$1"' _ "$(viab "shopping.$DOMAIN_T" / "${S[@]}")"
check "the data directory is 0700 and everything in it is owned by 10008 (the files are 0644 inside that private directory)" bash -c '[ "$(docker run --rm --user 0 --entrypoint sh --mount "type=volume,src=$1,dst=/v,volume-nocopy,readonly" "$2" -c "stat -c %a /v; find /v ! -user 10008 | wc -l" | tr "\n" " ")" = "700 0 " ]' _ "$VOL" "$IMG"

echo "--- Authentik down"
docker stop kftest-auth > /dev/null
c="$(via "shopping.$DOMAIN_T" / "${S[@]}" | cut -d' ' -f1)"
check "Authentik down: Koffan is NOT served (forward auth fails closed: got $c)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$c"
c="$(via "shopping.$DOMAIN_T" /static/manifest.json | cut -d' ' -f1)"
check "Authentik down: the static PWA files are still served (the allowlist is their only gate) [$c]" test "$c" = 200

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Koffan checks passed\n'
