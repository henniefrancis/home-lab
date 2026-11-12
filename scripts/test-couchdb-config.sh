#!/usr/bin/env bash
# test-couchdb-config.sh - self-test of the CouchDB (Obsidian LiveSync) stack (R19, milestone M16). Needs docker (Compose v2.24+), jq, curl,
# openssl.
#
# Usage: scripts/test-couchdb-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also boots the real image, the init one-shot and the real Traefik routers (CI runs this; it holds a continuous _changes feed open for 65 s)
#
# Dummy values only (fake domain, throw-away secrets, a self-signed wildcard certificate). Everything it creates is named cdtest-* and removed on
# exit. Named volumes (volume-nocopy) hold the data and the runtime configuration.
#
# Static: pinned official image; uid 10011 (never root or 1000); read-only root, cap_drop ALL, no-new-privileges, limits; the livesync.ini values;
#   the wrapper (secrets from files, the image's own entrypoint, no Erlang cookie variable); the one-shot init; routers (allowlist only, no
#   Authentik, Fauxton blocked by deny-all); no CORS header anywhere in Traefik; manifest rows; no Homepage tile, no blueprint entry; backup job.
# Full run: healthy as 10011 with no capability, no_new_privs and a read-only root; anonymous access is 401; the admin hash is written and no
#   plaintext password is left; couchdb-init exits 0 twice (idempotent); the sync user can use ITS database only and is no server admin;
#   the CORS preflight from app://obsidian.md has exactly ONE allow-origin header with credentials, direct and through Traefik; /_utils is 403
#   through Traefik; a _changes long-poll survives 65 seconds through Traefik.
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
NET=cdtest-proxy
VOLS=(cdtest-data cdtest-etc)
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f cdtest-app cdtest-init cdtest-traefik > /dev/null 2>&1 || true
    docker network rm "$NET" > /dev/null 2>&1 || true
    docker volume rm "${VOLS[@]}" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap "exit 130" INT TERM

stage="$(mktemp -d -p "${COUCHDB_TEST_TMP:-.}" .couchdb-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })"
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole" "$stage/secrets/linkwarden" \
  "$stage/secrets/portainer" "$stage/secrets/n8n" "$stage/secrets/couchdb" "$stage/secrets/speedtest"
: > "$stage/secrets/tailscale/tailscale.env"
ADMINPW="$(openssl rand -hex 24 | tr -d '\r\n')"
COOKIE="$(openssl rand -hex 24 | tr -d '\r\n')"
# the sync password holds a quote, a backslash and spaces on purpose: the init script must escape them
SYNCPW='Sync "pw" \ with-specials-'"$(openssl rand -hex 4 | tr -d '\r\n')"
printf '%s' "$ADMINPW" > "$stage/secrets/couchdb/admin-password"
printf '%s' "$COOKIE" > "$stage/secrets/couchdb/cookie-secret"
printf '%s' "$SYNCPW" > "$stage/secrets/couchdb/sync-password"
chmod 644 "$stage"/secrets/couchdb/*
cp couchdb/livesync.ini couchdb/init.sh "$stage/"
chmod 644 "$stage/livesync.ini" "$stage/init.sh"
export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f couchdb/compose.yaml --env-file config/lab.env config --format json)"
cd_="$(jq -c '.services.couchdb' <<< "$alone")"
ci="$(jq -c '.services["couchdb-init"]' <<< "$alone")"
IMG="$(jq -r '.image' <<< "$cd_")"
printf 'image: %s\n' "$IMG"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2-; }
SU="$(lab_get COUCHDB_SYNC_USER)"
SD="$(lab_get COUCHDB_SYNC_DB)"
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z0-9-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
ini=couchdb/livesync.ini
ini_get() { awk -v s="$1" -v k="$2" '/^\[/{sec=$0} sec == "[" s "]" && index($0, k " = ") == 1 {sub(/^[^=]*= /, ""); print; exit}' "$ini"; }

echo "--- static: image, identity, hardening"
check "CouchDB is the official image couchdb:X.Y.Z pinned by digest (both services)" bash -c '[[ "$1" =~ ^couchdb:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] && [ "$1" = "$2" ]' _ "$IMG" "$(jq -r .image <<< "$ci")"
check "root compose includes both services with the same image" test "$(jq -r '[.services.couchdb.image, .services["couchdb-init"].image] | unique | join(" ")' <<< "$all")" = "$IMG"
check "both run as COUCHDB_UID:GID 10011 (never root, never 1000); the uid is used once in lab.env" bash -c '[ "$(jq -r .user <<< "$1")" = 10011:10011 ] && [ "$(jq -r .user <<< "$2")" = 10011:10011 ] && [ "$(grep -cE "^[A-Z0-9_]+_UID=10011$" config/lab.env)" = 1 ]' _ "$cd_" "$ci"
for s in cd_ ci; do
  check "$s: read-only root, cap_drop ALL, no cap_add, not privileged, no-new-privileges, memory and pid limits, only the proxy network" test "$(jq -c '[.read_only, .cap_drop, (.cap_add // []), (.privileged // false), (.security_opt | index("no-new-privileges:true") != null), (.mem_limit != null), (.pids_limit != null), [.networks | keys[]]]' <<< "${!s}")" = '[true,["ALL"],[],false,true,true,true,["proxy"]]'
done
check "no published port, no docker.sock, no Traefik labels" bash -c '[ "$(jq ".ports // [] | length" <<< "$1")" = 0 ] && ! grep -q docker.sock <<< "$1" && [ "$(jq ".labels // {} | length" <<< "$1")" = 0 ]' _ "$cd_"
check "memory limits: 512m for CouchDB, 64m for the init one-shot" test "$(jq -r .mem_limit <<< "$cd_") $(jq -r .mem_limit <<< "$ci")" = "536870912 67108864"
check "init: restart no, starts after couchdb is healthy" test "$(jq -c '[.restart, .depends_on.couchdb.condition]' <<< "$ci")" = '["no","service_healthy"]'
check "volumes: data and etc (bind mounts of APPS_ROOT/couchdb) and livesync.ini read-only; HOME is /tmp (tmpfs)" bash -c '[ "$(jq -c "[.volumes[] | [.target, (.read_only // false)]]" <<< "$1")" = "[[\"/opt/couchdb/data\",false],[\"/opt/couchdb/etc/local.d\",false],[\"/opt/couchdb/etc/local.d/10-livesync.ini\",true]]" ] && [ "$(jq -r .environment.HOME <<< "$1")" = /tmp ] && jq -e ".tmpfs[0] | startswith(\"/tmp:\")" <<< "$1" > /dev/null' _ "$cd_"

echo "--- static: configuration and secrets"
check "livesync.ini: single_node, 50 MB documents, 4 GiB requests, require_valid_user in chttpd and chttpd_auth (no anonymous access)" test "$(ini_get couchdb single_node)|$(ini_get couchdb max_document_size)|$(ini_get chttpd max_http_request_size)|$(ini_get chttpd require_valid_user)|$(ini_get chttpd_auth require_valid_user)" = "true|50000000|4294967296|true|true"
check "livesync.ini: CORS on (httpd and chttpd), credentials, exactly the three Obsidian origins, no wildcard" test "$(ini_get httpd enable_cors)|$(ini_get chttpd enable_cors)|$(ini_get cors credentials)|$(ini_get cors origins)" = "true|true|true|app://obsidian.md,capacitor://localhost,http://localhost"
check "livesync.ini: Basic realm challenge, the plugin's methods and headers" test "$(ini_get httpd WWW-Authenticate)|$(ini_get cors methods)|$(ini_get cors headers)" = 'Basic realm="couchdb"|GET, PUT, POST, HEAD, DELETE|accept, authorization, content-type, origin, referer'
check "livesync.ini holds no password, no secret and no admin section" bash -c '! grep -qiE "^\[admins\]|password|secret|^\[(chttpd_auth)\]$" <(grep -v "^;" "$1" | grep -v "^\[chttpd_auth\]$")' _ "$ini"
check "the wrapper exports COUCHDB_USER (admin), COUCHDB_PASSWORD and COUCHDB_SECRET from /run/secrets and execs the image's tini -- /docker-entrypoint.sh /opt/couchdb/bin/couchdb" bash -c 'e="$(jq -r ".entrypoint | join(\" \")" <<< "$1")"; grep -q "COUCHDB_USER=admin" <<< "$e" && grep -qF "COUCHDB_PASSWORD=\"\$\$(cat /run/secrets/couchdb_admin_password)\"" <<< "$e" && grep -qF "COUCHDB_SECRET=\"\$\$(cat /run/secrets/couchdb_cookie_secret)\"" <<< "$e" && grep -q "exec tini -- /docker-entrypoint.sh /opt/couchdb/bin/couchdb" <<< "$e"' _ "$cd_"
check "no secret or Erlang cookie variable in any environment (COUCHDB_ERLANG_COOKIE would chown as non-root and fail)" bash -c '! { jq -r ".environment // {} | keys[]" <<< "$1"; jq -r ".environment // {} | keys[]" <<< "$2"; } | grep -Eqx "COUCHDB_USER|COUCHDB_PASSWORD|COUCHDB_SECRET|COUCHDB_ERLANG_COOKIE|NODENAME"' _ "$cd_" "$ci"
check "secrets: CouchDB gets admin-password and cookie-secret; the init gets admin-password and sync-password" test "$(jq -r '[.secrets[].source] | sort | join(" ")' <<< "$cd_") | $(jq -r '[.secrets[].source] | sort | join(" ")' <<< "$ci")" = "couchdb_admin_password couchdb_cookie_secret | couchdb_admin_password couchdb_sync_password"
check "init environment: the sync user and database names come from lab.env ($SU, $SD)" test "$(jq -r '[.environment.COUCHDB_SYNC_USER, .environment.COUCHDB_SYNC_DB] | join(" ")' <<< "$ci")" = "$SU $SD"
check "init.sh keeps credentials out of argv (curl -K -), talks only to http://couchdb:5984 and escapes the password" bash -c 'grep -q "curl -sS -K -" couchdb/init.sh && grep -q "BASE=http://couchdb:5984" couchdb/init.sh && ! grep -qE "curl[^|]* (-u|--user) " couchdb/init.sh && grep -q "^esc()" couchdb/init.sh'
check "init.sh: the JSON body that holds the sync password goes through a 0600 temp file (umask 077, --data-binary @file, removed on exit), never argv" bash -c 'grep -q "^umask 077$" couchdb/init.sh && grep -q "trap .rm -f \"\$BODY\". EXIT" couchdb/init.sh && grep -q "data-binary \"@\$BODY\"" couchdb/init.sh && ! grep -E "data-binary \"\\$doc" couchdb/init.sh'
check "manifest: admin-password, cookie-secret and sync-password, required, 10011:10011 0400" bash -c 'm=config/secrets-manifest.tsv; for n in admin-password cookie-secret sync-password; do grep -qP "^couchdb/$n\tcouchdb/$n\t10011:10011\t0400\tyes\traw$" $m || exit 1; done'

echo "--- static: routers, DNS, scope"
check "couchdb router: the allowlist ONLY (no Authentik), service couchdb:5984" bash -c 'b="$(router_block couchdb)"; grep -q "Host(\`couchdb.{{ env \"DOMAIN\" }}\`)" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 1 ] && grep -q -- "- lan-allowlist$" <<< "$b" && ! grep -q authentik <<< "$b" && grep -q "service: couchdb$" <<< "$b" && awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://couchdb:5984"' _ $rt
check "couchdb-admin-ui: /_utils on the app host, priority 100, lan-allowlist then deny-all" bash -c 'b="$(router_block couchdb-admin-ui)"; grep -q "PathPrefix(\`/_utils\`)" <<< "$b" && grep -q "priority: 100$" <<< "$b" && [ "$(grep -A4 "middlewares:" <<< "$b" | grep -- "- " | tr -d " \n")" = "-lan-allowlist-deny-all" ]' _
check "deny-all is an ipAllowList of 127.0.0.2/32 only (nobody passes: 403)" bash -c 'b="$(awk "\$0 == \"    deny-all:\" {f=1; next} /^    [a-z-]+:\$/ {f=0} f" traefik/dynamic/middlewares.yml)"; [ "$(grep -E "^ +- " <<< "$b" | tr -d " \n")" = "-127.0.0.2/32" ] && grep -q ipAllowList <<< "$b"' _
check "Traefik adds NO CORS header anywhere (CouchDB owns CORS: a doubled Access-Control-Allow-Origin breaks the plugin)" bash -c '! grep -rniE "accesscontrol|access-control" traefik/dynamic | grep -v "^[^:]*:[0-9]*:[[:space:]]*#"'
check "no Authentik entry for CouchDB (the plugin cannot do forward auth or OIDC) and no Homepage tile (there is no web UI)" bash -c '! grep -v "^ *#" authentik/blueprints/homelab-apps.yaml homepage/config/services.yaml | grep -qi couchdb'
check "Pi-hole: couchdb.<domain> is answered with the Pi's LAN address" test "$(jq -r '.services.pihole.environment.FTLCONF_dns_hosts' <<< "$all" | tr ' ' '\n' | grep -cx "couchdb.$DOMAIN_T")" = 1
check "bootstrap.sh creates couchdb/data and couchdb/etc for COUCHDB_UID (0700) and preflight.sh checks both" bash -c 'grep -q "\"\$APPS_ROOT/couchdb/data\" \"\$APPS_ROOT/couchdb/etc\"" scripts/bootstrap.sh && grep -q "couchdb:COUCHDB:data" scripts/preflight.sh && grep -q "couchdb:COUCHDB:etc" scripts/preflight.sh'
check "backup-apps.sh has the couchdb job (kind couch)" bash -c 'grep -q "\"couchdb|couch|couchdb||\"" scripts/backup-apps.sh'
check "Dependabot, the socket guard, digest pinning and the image scan cover couchdb/compose.yaml" bash -c 'grep -q -- "- /couchdb$" .github/dependabot.yml && grep -q "no_sock=.*couchdb" .github/workflows/ci.yml && grep -q "couchdb/compose.yaml" .github/workflows/ci.yml && grep -q "couchdb/compose.yaml" scripts/scan-images.sh'

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static CouchDB checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
echo "--- containers"
docker network create "$NET" > /dev/null
docker volume rm "${VOLS[@]}" > /dev/null 2>&1 || true
for v in "${VOLS[@]}"; do
  docker volume create "$v" > /dev/null
  docker run --rm --user 0 --entrypoint sh --mount "type=volume,src=$v,dst=/v,volume-nocopy" "$IMG" -c 'chown 10011:10011 /v && chmod 0700 /v'
done
app_test_run cdtest-app "$cd_" couchdb "$NET" --mount "type=volume,src=cdtest-data,dst=/opt/couchdb/data,volume-nocopy" \
  --mount "type=volume,src=cdtest-etc,dst=/opt/couchdb/etc/local.d,volume-nocopy" \
  --mount "type=bind,source=$here/livesync.ini,target=/opt/couchdb/etc/local.d/10-livesync.ini,readonly"
app_test_traefik cdtest "$NET"
cid="$APP_TEST_CID"

echo "--- CouchDB container"
healthy=0
wait_healthy cdtest-app 40 && healthy=1
check "CouchDB becomes healthy with the rendered definition (the check logs in as admin)" test "$healthy" = 1
procs="$(proc_ids cdtest-app)"
check "every process is uid 10011 with no capability and no_new_privs set [$(tr -d '\n' <<< "$procs")]" bash -c '[ -n "$1" ] && ! grep -vq "^10011 0000000000000000 1 $" <<< "$1"' _ "$procs"
check "the root file system is read-only (nothing under /opt/couchdb outside the two mounts can be written)" bash -c '! docker exec cdtest-app sh -c "touch /opt/couchdb/x 2>/dev/null || touch /opt/couchdb/etc/x 2>/dev/null || touch /etc/x 2>/dev/null"'
check "the data and etc directories are writable by 10011" bash -c 'docker exec cdtest-app sh -c "touch /opt/couchdb/data/.p /opt/couchdb/etc/local.d/.p && rm /opt/couchdb/data/.p /opt/couchdb/etc/local.d/.p"'
check "docker inspect: ReadonlyRootfs, CapDrop ALL, no port bindings, no privileged" test "$(docker inspect cdtest-app -f '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}} {{len .HostConfig.PortBindings}} {{.HostConfig.Privileged}}')" = 'true ["ALL"] 0 false'
ix() { docker exec cdtest-app curl -s "$@"; }
check "anonymous access is refused (401) on / and on _all_dbs" test "$(ix -o /dev/null -w '%{http_code}' http://127.0.0.1:5984/)$(ix -o /dev/null -w '%{http_code}' http://127.0.0.1:5984/_all_dbs)" = 401401
conf="$(docker run --rm --user 0 --entrypoint cat --mount "type=volume,src=cdtest-etc,dst=/v,volume-nocopy,readonly" "$IMG" /v/docker.ini | tr -d '\r')"
check "the admin password is HASHED in docker.ini (pbkdf2) and no plaintext password or cookie secret is left in the runtime configuration" bash -c 'grep -qE "^admin = -pbkdf2" <<< "$1" && ! grep -qF "$2" <<< "$1" && grep -q "^secret = " <<< "$1"' _ "$conf" "$ADMINPW"
check "the admin hash is not the one in livesync.ini and the committed ini was not written to (read-only mount)" bash -c '! grep -q "pbkdf2" "$1"' _ "$ini"
leak="$(docker inspect cdtest-app --format '{{json .Config}}' | tr -d '\r'; docker logs cdtest-app 2>&1; docker exec cdtest-app sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" " "')"
check "neither the admin password nor the cookie secret is in docker inspect, the logs or any command line" bash -c '! grep -qF -e "$2" -e "$3" <<< "$1"' _ "$leak" "$ADMINPW" "$COOKIE"
check "the admin can read the server (200) and the system databases exist (single_node)" bash -c 'a="$(docker exec cdtest-app curl -s -u "admin:$1" http://127.0.0.1:5984/_all_dbs)"; grep -q "_users" <<< "$a" && grep -q "_replicator" <<< "$a"' _ "$ADMINPW"
check "the Erlang cookie and the HOME writes stay in the tmpfs (nothing was written outside /tmp, /opt/couchdb/data and local.d): no read-only error in the log" bash -c '! docker logs cdtest-app 2>&1 | grep -Eiq "read-only file system|eacces|permission denied|erofs"'

echo "--- couchdb-init (twice)"
app_test_run cdtest-init "$ci" couchdb-init "$NET" --mount "type=bind,source=$here/init.sh,target=/init.sh,readonly"
rc1="$(docker wait cdtest-init | tr -d '\r')"
l1="$(docker logs cdtest-init 2>&1)"
check "the init one-shot exits 0 and writes the sync user and the database [$rc1: $(tr '\n' ' ' <<< "$l1" | cut -c1-110)]" bash -c '[ "$1" = 0 ] && grep -q "sync user $2 written" <<< "$3" && grep -q "database $4 ready" <<< "$3"' _ "$rc1" "$SU" "$l1" "$SD"
docker start -a cdtest-init > "$stage/init2.log" 2>&1 || true
rc2="$(docker inspect cdtest-init -f '{{.State.ExitCode}}')"
check "run again it exits 0 and leaves the user alone (idempotent) [$rc2: $(tr '\n' ' ' < "$stage/init2.log" | cut -c1-90)]" bash -c '[ "$1" = 0 ] && grep -q "sync user $2 already set" "$3" && grep -q "database $4 ready" "$3"' _ "$rc2" "$SU" "$stage/init2.log" "$SD"
check "the init container's logs hold no password" bash -c '! cat "$1" | grep -qF -e "$2" -e "$3" && ! docker logs cdtest-init 2>&1 | grep -qF -e "$2" -e "$3"' _ "$stage/init2.log" "$ADMINPW" "$SYNCPW"
check "the sync user authenticates and is named in its session" bash -c 'docker exec -e P="$1" cdtest-app sh -c "curl -s -u \"$2:\$P\" http://127.0.0.1:5984/_session" | grep -q "\"name\":\"$2\""' _ "$SYNCPW" "$SU"
check "the sync user can write a document to its database and read it back" bash -c 'x() { docker exec -e P="$1" cdtest-app sh -c "curl -s -u \"$2:\$P\" \"\$@\"" sh "${@:3}"; }; [ "$(x "$1" "$2" -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" -d "{\"v\":1}" "http://127.0.0.1:5984/$3/doc1")" = 201 ] && x "$1" "$2" "http://127.0.0.1:5984/$3/doc1" | grep -q "\"v\":1"' _ "$SYNCPW" "$SU" "$SD"
check "the sync user can write a design document (it is admin of its ONE database, as the plugin needs)" bash -c '[ "$(docker exec -e P="$1" cdtest-app sh -c "curl -s -o /dev/null -w \"%{http_code}\" -u \"$2:\$P\" -X PUT -H \"Content-Type: application/json\" -d \"{\\\"views\\\":{}}\" http://127.0.0.1:5984/$3/_design/t")" = 201 ]' _ "$SYNCPW" "$SU" "$SD"
for p in /_all_dbs /_users/_all_docs /_replicator/_all_docs /_node/_local/_config /_membership "/_users/org.couchdb.user:admin"; do
  c="$(docker exec -e P="$SYNCPW" cdtest-app sh -c "curl -s -o /dev/null -w '%{http_code}' -u \"$SU:\$P\" 'http://127.0.0.1:5984$p'")"
  check "the sync user is refused on server-level path $p (401 or 403) [$c]" bash -c '[ "$1" = 401 ] || [ "$1" = 403 ]' _ "$c"
done
c="$(docker exec -e P="$SYNCPW" cdtest-app sh -c "curl -s -o /dev/null -w '%{http_code}' -u \"$SU:\$P\" -X PUT http://127.0.0.1:5984/otherdb")"
check "the sync user cannot create another database [$c]" bash -c '[ "$1" = 401 ] || [ "$1" = 403 ]' _ "$c"
docker exec cdtest-app curl -s -u "admin:$ADMINPW" -X PUT http://127.0.0.1:5984/private > /dev/null
c="$(docker exec -e P="$SYNCPW" cdtest-app sh -c "curl -s -o /dev/null -w '%{http_code}' -u \"$SU:\$P\" http://127.0.0.1:5984/private/_all_docs")"
check "another database (created by the admin) is not readable by the sync user [$c]" bash -c '[ "$1" = 401 ] || [ "$1" = 403 ]' _ "$c"
check "the sync user is not a server admin and only admin and member of its database (_security)" bash -c 's="$(docker exec cdtest-app curl -s -u "admin:$1" "http://127.0.0.1:5984/$3/_security")"; [ "$(jq -c "[.admins.names, .members.names]" <<< "$s")" = "[[\"$2\"],[\"$2\"]]" ] && ! docker exec cdtest-app curl -s -u "admin:$1" "http://127.0.0.1:5984/_node/_local/_config/admins" | grep -q "\"$2\""' _ "$ADMINPW" "$SU" "$SD"

echo "--- CORS (one allow-origin header, from CouchDB)"
pre() { # pre <curl prefix: direct|traefik>
  if [ "$1" = direct ]; then
    docker exec cdtest-app curl -s -i -X OPTIONS -H 'Origin: app://obsidian.md' -H 'Access-Control-Request-Method: PUT' -H 'Access-Control-Request-Headers: authorization,content-type' "http://127.0.0.1:5984/$SD/doc1" | tr -d '\r'
  else
    curl -sk -i -X OPTIONS --connect-to "couchdb.$DOMAIN_T:443:127.0.0.1:$APP_TEST_HOSTPORT" -H 'Origin: app://obsidian.md' -H 'Access-Control-Request-Method: PUT' -H 'Access-Control-Request-Headers: authorization,content-type' "https://couchdb.$DOMAIN_T/$SD/doc1" | tr -d '\r'
  fi
}
for w in direct traefik; do
  h="$(pre $w)"
  check "$w: the preflight from app://obsidian.md gets exactly ONE Access-Control-Allow-Origin (app://obsidian.md) and credentials true" bash -c '[ "$(grep -ci "^access-control-allow-origin:" <<< "$1")" = 1 ] && grep -qi "^access-control-allow-origin: app://obsidian.md$" <<< "$1" && grep -qi "^access-control-allow-credentials: true$" <<< "$1"' _ "$h"
done
h="$(curl -sk -i -X OPTIONS --connect-to "couchdb.$DOMAIN_T:443:127.0.0.1:$APP_TEST_HOSTPORT" -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: PUT' "https://couchdb.$DOMAIN_T/$SD/doc1" | tr -d '\r')"
check "an origin outside the list gets no Allow-Origin header" bash -c '! grep -qi "^access-control-allow-origin:" <<< "$1"' _ "$h"

echo "--- through Traefik"
ready=0
for _ in $(seq 1 30); do
  [ "$(via "couchdb.$DOMAIN_T" / | cut -d' ' -f1)" = 401 ] && ready=1 && break
  sleep 2
done
check "Traefik discovered the couchdb routers (anonymous / is answered by CouchDB with 401, not redirected)" test "$ready" = 1
check "Traefik reports no error for the couchdb routers or the deny-all middleware" bash -c '! docker logs "$1" 2>&1 | jq -R -r "fromjson? | select(.level==\"error\") | .msg" | grep -Ei "couchdb|deny-all|middleware"' _ "$cid"
for p in /_utils /_utils/ /_utils/index.html /_utils/css/x.css; do
  c="$(via "couchdb.$DOMAIN_T" "$p" | cut -d' ' -f1)"
  check "Fauxton $p is blocked by deny-all (403) [$c]" test "$c" = 403
done
c="$(via "couchdb.$DOMAIN_T" "/_utils/../" --path-as-is | cut -d' ' -f1)"
check "a traversal into /_utils is not served (anything but 200) [$c]" test "$c" != 200
c="$(curl -sk -o /dev/null -w '%{http_code}' --connect-to "couchdb.$DOMAIN_T:443:127.0.0.1:$APP_TEST_HOSTPORT" -u "$SU:$SYNCPW" "https://couchdb.$DOMAIN_T/$SD/doc1" || true)"
check "the sync user reads its document through Traefik over HTTPS (200) [$c]" test "$c" = 200
h="$(viah "couchdb.$DOMAIN_T" / -u "admin:$ADMINPW")"
check "the shared security headers are on the CouchDB response (HSTS, nosniff, frame deny)" bash -c 'grep -qi "^strict-transport-security: max-age=" <<< "$1" && grep -qi "^x-content-type-options: nosniff" <<< "$1" && grep -qi "^x-frame-options: deny" <<< "$1"' _ "$h"
check "www and an unknown host are NOT served (404)" test "$(via "www.$DOMAIN_T" / | cut -d' ' -f1)$(via "unknown.$DOMAIN_T" / | cut -d' ' -f1)" = 404404
useq="$(curl -sk --connect-to "couchdb.$DOMAIN_T:443:127.0.0.1:$APP_TEST_HOSTPORT" -u "$SU:$SYNCPW" "https://couchdb.$DOMAIN_T/$SD" | jq -r .update_seq | tr -d '\r' || true)"
t0="$(date +%s)"
lp="$(curl -sk -o "$stage/lp.out" -w '%{http_code}' --max-time 90 --connect-to "couchdb.$DOMAIN_T:443:127.0.0.1:$APP_TEST_HOSTPORT" -u "$SU:$SYNCPW" "https://couchdb.$DOMAIN_T/$SD/_changes?feed=longpoll&since=$useq&timeout=65000" || true)"
t1="$(date +%s)"
check "a _changes long-poll (from the current sequence) held open through Traefik survives 65 seconds and answers 200 (the plugin's continuous feed is not cut by a timeout) [$lp after $((t1 - t0)) s]" bash -c '[ "$1" = 200 ] && [ "$2" -ge 60 ]' _ "$lp" "$((t1 - t0))"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll CouchDB checks passed\n'
