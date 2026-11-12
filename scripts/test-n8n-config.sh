#!/usr/bin/env bash
# test-n8n-config.sh - self-test of the n8n stack (R19, milestone M17). Needs docker (Compose v2.24+), jq, curl, openssl.
#
# Usage: scripts/test-n8n-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also boots the real image and the real Traefik routers (CI runs this)
#
# Dummy values only (fake domain, a throw-away encryption key, a self-signed wildcard certificate, a stub in place of authentik-server). Everything
# it creates is named n8test-* and removed on exit. NOT covered (needs an owner account and a workflow, i.e. a manual check in the runbook): the
# static files a Form Trigger page loads; only the exact entry-point prefixes are on the hooks router, and nothing else may be added without a test.
#
# Static: pinned image; uid 10010 (never root or 1000); read-only root, cap_drop ALL, no-new-privileges, limits; every environment name and value
#   the plan lists; the key only as a FILE variable; the three routers (the exact six hook prefixes with trailing slashes, allowlist only; forward
#   auth for everything else); the Authentik triple (admins only) and the outpost; tile; DNS record; manifest; backup jobs.
# Full run: healthy; uid 10010, no capability, no_new_privs, read-only root; n8n uses the key from the file (its config file holds exactly that
#   key, no other) and the key is in no log or `docker inspect`; through Traefik anonymous requests to / and to /rest/ are redirected to the
#   outpost while exactly the webhook and form prefixes reach n8n without it; look-alike paths (/webhooks, /formx, /webhook without the slash,
#   a traversal into /rest/) do not bypass; Authentik down fails the editor closed but not the hooks (the allowlist is their gate).
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
NET=n8test-proxy
VOL=n8test-data
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f n8test-app n8test-traefik n8test-auth > /dev/null 2>&1 || true
    docker network rm "$NET" > /dev/null 2>&1 || true
    docker volume rm "$VOL" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap "exit 130" INT TERM

stage="$(mktemp -d -p "${N8N_TEST_TMP:-.}" .n8n-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })"
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole" "$stage/secrets/linkwarden" \
  "$stage/secrets/portainer" "$stage/secrets/n8n" "$stage/secrets/couchdb" "$stage/secrets/speedtest"
: > "$stage/secrets/tailscale/tailscale.env"
KEY="$(openssl rand -hex 32 | tr -d '\r\n')"
printf '%s' "$KEY" > "$stage/secrets/n8n/encryption-key"
chmod 644 "$stage/secrets/n8n/encryption-key"
export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f n8n/compose.yaml --env-file config/lab.env config --format json)"
n8="$(jq -c '.services.n8n' <<< "$alone")"
IMG="$(jq -r '.image' <<< "$n8")"
printf 'image: %s\n' "$IMG"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2-; }
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z0-9-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
bp=authentik/blueprints/homelab-apps.yaml
HOOKS="/form-test/ /form-waiting/ /form/ /webhook-test/ /webhook-waiting/ /webhook/"
hook_prefixes() { router_block n8n-hooks | tr '\n' ' ' | grep -oE 'PathPrefix\(`[^`]+`\)' | sed -E 's/^PathPrefix\(`(.*)`\)$/\1/' | LC_ALL=C sort | tr '\n' ' '; }

echo "--- static: image, identity, hardening"
check "n8n is a pinned n8nio/n8n X.Y.Z by digest (the stable line)" bash -c '[[ "$1" =~ ^n8nio/n8n:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMG"
check "root compose includes n8n with the same image" test "$(jq -r '.services.n8n.image' <<< "$all")" = "$IMG"
check "runs as N8N_UID:GID 10010 (overriding the image's node = 1000; never root); the uid is used once in lab.env" bash -c '[ "$(jq -r .user <<< "$1")" = 10010:10010 ] && [ "$(grep -cE "^[A-Z0-9_]+_UID=10010$" config/lab.env)" = 1 ]' _ "$n8"
check "read-only root, cap_drop ALL, no cap_add, not privileged, no-new-privileges, 1g memory, pids 512, ONLY its own n8n network (not proxy)" test "$(jq -c '[.read_only, .cap_drop, (.cap_add // []), (.privileged // false), (.security_opt | index("no-new-privileges:true") != null), .mem_limit, .pids_limit, [.networks | keys[]]]' <<< "$n8")" = '[true,["ALL"],[],false,true,"1073741824",512,["n8n"]]'
check "no published port, no docker.sock, no Traefik labels" bash -c '[ "$(jq ".ports // [] | length" <<< "$1")" = 0 ] && ! grep -q docker.sock <<< "$1" && [ "$(jq ".labels // {} | length" <<< "$1")" = 0 ]' _ "$n8"
check "M-1: only Traefik and n8n are on the n8n network (n8n cannot reach koffan, couchdb or the other apps); the network is external and NOT internal (bootstrap.sh creates it without --internal)" bash -c '[ "$(jq -r "[.services | to_entries[] | select(.value.networks // {} | has(\"n8n\")) | .key] | sort | join(\" \")" <<< "$1")" = "n8n traefik" ] && grep -q "^ensure_network n8n --subnet" scripts/bootstrap.sh && grep -q "linkwarden-internal n8n; do" scripts/preflight.sh' _ "$all"
check "N8N_SUBNET is pinned in lab.env, is a /24 that overlaps none of PROXY_SUBNET, AUTHENTIK_AUTH_SUBNET, OIDC_SUBNET, and bootstrap and preflight use it" bash -c 'n="$(grep -E "^N8N_SUBNET=" config/lab.env | cut -d= -f2)"; [[ "$n" =~ ^172\.30\.[0-9]+\.0/24$ ]] && for k in PROXY_SUBNET AUTHENTIK_AUTH_SUBNET OIDC_SUBNET; do [ "$(grep -E "^$k=" config/lab.env | cut -d= -f2)" != "$n" ] || exit 1; done && grep -q "N8N_SUBNET" scripts/bootstrap.sh && grep -q "N8N_SUBNET" scripts/preflight.sh'
check "M-1: NODES_EXCLUDE removes executeCommand and localFileTrigger; file access is restricted to a scratch directory on the tmpfs (never the data volume)" bash -c 'jq -e ".environment.NODES_EXCLUDE | fromjson == [\"n8n-nodes-base.executeCommand\",\"n8n-nodes-base.localFileTrigger\"]" <<< "$1" > /dev/null && [ "$(jq -r .environment.N8N_RESTRICT_FILE_ACCESS_TO <<< "$1")" = /tmp/n8n-files ]' _ "$n8"
check "writable only: the data directory (user folder /home/node/.n8n), a 256m tmpfs /tmp (HOME) and a 64m tmpfs /home/node/.cache (static assets)" test "$(jq -c '[[.volumes[] | [.source, .target]], .tmpfs, .environment.HOME, .environment.N8N_USER_FOLDER]' <<< "$n8" | sed "s#$here#APPS#")" = '[[["APPS/n8n/data","/home/node/.n8n"]],["/tmp:size=256m,uid=10010,gid=10010,mode=0700","/home/node/.cache:size=64m,uid=10010,gid=10010,mode=0700"],"/tmp","/home/node"]'

echo "--- static: environment and secrets"
check "URLs and proxy: host, https, editor base URL, N8N_WEBHOOK_URL (not the deprecated WEBHOOK_URL), one proxy hop" test "$(jq -r '.environment | [.N8N_HOST, .N8N_PROTOCOL, .N8N_EDITOR_BASE_URL, .N8N_WEBHOOK_URL, .N8N_PROXY_HOPS, (has("WEBHOOK_URL"))] | join(" ")' <<< "$n8")" = "n8n.$DOMAIN_T https https://n8n.$DOMAIN_T/ https://n8n.$DOMAIN_T/ 1 false"
check "time zone from lab.env (GENERIC_TIMEZONE and TZ), SQLite" test "$(jq -r '.environment | [.GENERIC_TIMEZONE, .TZ, .DB_TYPE] | join(" ")' <<< "$n8")" = "$(lab_get TZ) $(lab_get TZ) sqlite"
check "telemetry, update notices, personalisation, community packages, the public API and environment access from Code nodes are OFF" test "$(jq -r '.environment | [.N8N_DIAGNOSTICS_ENABLED, .N8N_VERSION_NOTIFICATIONS_ENABLED, .N8N_PERSONALIZATION_ENABLED, .N8N_COMMUNITY_PACKAGES_ENABLED, .N8N_PUBLIC_API_DISABLED, .N8N_BLOCK_ENV_ACCESS_IN_NODE] | join(" ")' <<< "$n8")" = "false false false false true true"
check "executions are pruned: 168 hours, 5000 executions; Node heap capped at 768 MB" test "$(jq -r '.environment | [.EXECUTIONS_DATA_PRUNE, .EXECUTIONS_DATA_MAX_AGE, .EXECUTIONS_DATA_PRUNE_MAX_COUNT, .NODE_OPTIONS] | join(" ")' <<< "$n8")" = "true 168 5000 --max-old-space-size=768"
check "the encryption key only as N8N_ENCRYPTION_KEY_FILE=/run/secrets/n8n_encryption_key (never N8N_ENCRYPTION_KEY), one secret" bash -c '[ "$(jq -r .environment.N8N_ENCRYPTION_KEY_FILE <<< "$1")" = /run/secrets/n8n_encryption_key ] && ! jq -r ".environment | keys[]" <<< "$1" | grep -Eqx "N8N_ENCRYPTION_KEY|N8N_BASIC_AUTH_PASSWORD|DB_POSTGRESDB_PASSWORD" && [ "$(jq -r "[.secrets[].source] | join(\" \")" <<< "$1")" = n8n_encryption_key ]' _ "$n8"
check "manifest: n8n/encryption-key, required, 10010:10010 0400" bash -c 'grep -qP "^n8n/encryption-key\tn8n/encryption-key\t10010:10010\t0400\tyes\traw$" config/secrets-manifest.tsv'
check "the compose file holds no literal key (64 hex characters, comments and the image digest aside)" bash -c '! grep -v "^[[:space:]]*#" n8n/compose.yaml | grep -v "image:" | grep -qE "[0-9a-f]{64}"'

echo "--- static: routers, Authentik, tile, record, backups"
check "n8n router: allowlist then Authentik forward auth, priority 10, service n8n:5678" bash -c 'b="$(router_block n8n)"; grep -q "Host(\`n8n.{{ env \"DOMAIN\" }}\`)" <<< "$b" && grep -q "priority: 10$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -- "- " | tr -d " \n")" = "-lan-allowlist-authentik" ] && grep -q "service: n8n$" <<< "$b" && awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://n8n:5678"' _ $rt
check "n8n-outpost: the outpost path on the app host, priority 100, allowlist only, service authentik" bash -c 'b="$(router_block n8n-outpost)"; grep -q "PathPrefix(\`/outpost.goauthentik.io/\`)" <<< "$b" && grep -q "priority: 100$" <<< "$b" && grep -q "service: authentik$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 1 ]' _
check "n8n-hooks: priority 50, the allowlist ONLY (no Authentik), service n8n" bash -c 'b="$(router_block n8n-hooks)"; grep -q "priority: 50$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 1 ] && grep -q -- "- lan-allowlist$" <<< "$b" && ! grep -q authentik <<< "$(grep -A4 "middlewares:" <<< "$b")" && grep -q "service: n8n$" <<< "$b"' _
check "n8n-hooks lists EXACTLY the six prefixes /webhook/ /webhook-test/ /webhook-waiting/ /form/ /form-test/ /form-waiting/ (trailing slashes), each with PathPrefix and no regex, no wildcard, no /rest/, no /assets/" bash -c '[ "$1" = "$2" ] && ! router_block n8n-hooks | grep -qE "PathRegexp|HostRegexp|[*]|/rest|/assets"' _ "$(hook_prefixes)" "$HOOKS "
check "blueprint: provider homelab-n8n (forward_single, n8n.<domain>), application n8n bound to homelab-admins ONLY, on the embedded outpost" bash -c 'b="$(awk "/id: provider-n8n/{f=1} f&&/id: app-n8n/{exit} f" "$1")"; grep -q "mode: forward_single" <<< "$b" && grep -q "external_host: !Format \[\"https://n8n.%s\", !Env DOMAIN\]" <<< "$b" && [ "$(awk "/target: !KeyOf app-n8n/{getline; print}" "$1" | tr -d " ")" = "group:!KeyOfgroup-admins" ] && awk "/id: embedded-outpost/{f=1} f" "$1" | grep -q -- "- !KeyOf provider-n8n"' _ $bp
check "Homepage: the n8n tile is live in Tools" bash -c 'awk "/^- Tools:/{f=1;next} /^- /{f=0} f" homepage/config/services.yaml | grep -q "href: https://n8n.{{HOMEPAGE_VAR_DOMAIN}}/"'
check "Pi-hole: n8n.<domain> is answered with the Pi's LAN address" test "$(jq -r '.services.pihole.environment.FTLCONF_dns_hosts' <<< "$all" | tr ' ' '\n' | grep -cx "n8n.$DOMAIN_T")" = 1
check "bootstrap.sh creates n8n/data for N8N_UID (0700) and preflight.sh checks it" bash -c 'grep -q "install -d -m 0700 -o \"\$N8_UID\" -g \"\$N8_GID\" \"\$APPS_ROOT/n8n/data\"" scripts/bootstrap.sh && grep -q "n8n:N8N:data" scripts/preflight.sh'
check "backup-apps.sh: n8n-db is a sqlite job; n8n-files is a tar WITHOUT the database and WITHOUT n8n's config file (it holds a copy of the key)" bash -c 'grep -q "\"n8n-db|sqlite|n8n|data/database.sqlite|\"" scripts/backup-apps.sh && grep -q "\"n8n-files|tar|n8n|data|database.sqlite\*,config\"" scripts/backup-apps.sh'
check "bootstrap.sh installs sqlite3 (the backup tool) and Dependabot, the socket guard, digest pinning and the image scan cover n8n" bash -c 'grep -q "sqlite3:sqlite3" scripts/bootstrap.sh && grep -q -- "- /n8n$" .github/dependabot.yml && grep -q "no_sock=.* n8n" .github/workflows/ci.yml && grep -q "n8n/compose.yaml" .github/workflows/ci.yml && grep -q "n8n/compose.yaml" scripts/scan-images.sh'

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static n8n checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
echo "--- containers"
docker network create "$NET" > /dev/null
docker volume rm "$VOL" > /dev/null 2>&1 || true
docker volume create "$VOL" > /dev/null
docker run --rm --user 0 --entrypoint sh --mount "type=volume,src=$VOL,dst=/v,volume-nocopy" "$IMG" -c 'chown 10010:10010 /v && chmod 0700 /v'
app_test_run n8test-app "$n8" n8n "$NET" --mount "type=volume,src=$VOL,dst=/home/node/.n8n,volume-nocopy"
app_test_stub_auth n8test "$NET"
app_test_traefik n8test "$NET"
cid="$APP_TEST_CID"

echo "--- n8n container"
healthy=0
wait_healthy n8test-app 60 && healthy=1
check "n8n becomes healthy with the rendered definition (wget /healthz)" test "$healthy" = 1
sleep 25
check "n8n is still running 25 seconds after it first answered (it crashed at start-up once without a writable .cache)" test "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' n8test-app)" = "true 0"
procs="$(proc_ids n8test-app)"
check "every process is uid 10010 with no capability and no_new_privs set [$(tr -d '\n' <<< "$procs")]" bash -c '[ -n "$1" ] && ! grep -vq "^10010 0000000000000000 1 $" <<< "$1"' _ "$procs"
check "the root file system is read-only (the application and /etc cannot be written)" bash -c '! docker exec n8test-app sh -c "touch /usr/local/lib/x 2>/dev/null || touch /etc/x 2>/dev/null || touch /home/node/x 2>/dev/null"'
check "the data directory is writable by 10010 and holds the SQLite database" bash -c 'docker exec n8test-app sh -c "touch /home/node/.n8n/.p && rm /home/node/.n8n/.p && test -s /home/node/.n8n/database.sqlite"'
cfg="$(docker run --rm --user 0 --entrypoint cat --mount "type=volume,src=$VOL,dst=/v,volume-nocopy,readonly" "$IMG" /v/config | tr -d '\r')"
check "n8n uses the key from the secret file: its config file holds exactly that key and no other [$(jq -r '.encryptionKey // "none"' <<< "$cfg" | cut -c1-6)...]" bash -c '[ "$(jq -r .encryptionKey <<< "$1")" = "$2" ]' _ "$cfg" "$KEY"
leak="$(docker inspect n8test-app --format '{{json .Config}}' | tr -d '\r'; docker logs n8test-app 2>&1)"
check "the encryption key is in no docker inspect output and no log line" bash -c '! grep -qF "$2" <<< "$1"' _ "$leak" "$KEY"
check "no proxy-trust or rate-limit error in the log (N8N_PROXY_HOPS=1 matches the one Traefik hop), and no read-only file system error" bash -c '! docker logs n8test-app 2>&1 | grep -Eiq "ERR_ERL|trust proxy|read-only file system|EACCES|EROFS"'
check "docker inspect: ReadonlyRootfs, CapDrop ALL, no port bindings, not privileged" test "$(docker inspect n8test-app -f '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}} {{len .HostConfig.PortBindings}} {{.HostConfig.Privileged}}')" = 'true ["ALL"] 0 false'

echo "--- through Traefik (real flags, routers and middlewares; stub outpost)"
ready=0
for _ in $(seq 1 30); do
  case "$(via "n8n.$DOMAIN_T" /)" in 302*) ready=1 && break ;; esac
  sleep 2
done
check "Traefik discovered the n8n routers (an anonymous request is answered with 302)" test "$ready" = 1
check "Traefik reports no error for the n8n routers or the authentik middleware" bash -c '! docker logs "$1" 2>&1 | jq -R -r "fromjson? | select(.level==\"error\") | .msg" | grep -Ei "n8n|authentik|outpost|forwardauth|middleware"' _ "$cid"
S=(-H 'Cookie: stub_session=ok')
for p in / /signin /setup /healthz /rest/settings /rest/login /rest/owner/setup /rest/workflows /types/nodes.json /assets/x.js /webhook /webhooks/x /webhook-testing/x /form /formx /forms/x /form-tests/x /webhook-wait/x; do
  r="$(via "n8n.$DOMAIN_T" "$p")"
  check "anonymous GET $p is redirected to the Authentik authorize endpoint (n8n not reached) [$r]" bash -c '[[ "$1" == "302 https://auth.lab.example.test/application/o/authorize/"* ]]' _ "$r"
done
for m in POST PUT DELETE; do
  r="$(via "n8n.$DOMAIN_T" /rest/login -X "$m" -d '{}')"
  check "anonymous $m /rest/login is redirected to Authentik [$r]" bash -c '[[ "$1" == "302 https://auth.lab.example.test/"* ]]' _ "$r"
done
check "a forged identity header does not bypass forward auth (still 302)" bash -c '[[ "$1" == 302* ]]' _ "$(via "n8n.$DOMAIN_T" /rest/settings -H 'X-authentik-username: akadmin' -H 'X-authentik-groups: homelab-admins')"
for p in $HOOKS; do
  r="$(via "n8n.$DOMAIN_T" "${p}n8-test-path")"
  check "anonymous ${p}n8-test-path reaches n8n WITHOUT the outpost (n8n answers 404, or 500 for a waiting path with no execution; never a redirect) [$r]" bash -c '[ "${1%% *}" = 404 ] || [ "${1%% *}" = 500 ]' _ "$r"
done
r="$(via "n8n.$DOMAIN_T" /webhook/n8-test-path -X POST -H 'Content-Type: application/json' -d '{"a":1}')"
check "an anonymous POST to a webhook path reaches n8n too (404: no workflow registered, but not redirected) [$r]" bash -c '[ "${1%% *}" = 404 ]' _ "$r"
r="$(via "n8n.$DOMAIN_T" "/webhook/../rest/settings" --path-as-is)"
check "a traversal from a hook prefix into /rest/ is not served anonymously [$r]" bash -c '[[ "$1" == 302* ]] || [ "${1%% *}" = 400 ] || [ "${1%% *}" = 404 ]' _ "$r"
r="$(via "n8n.$DOMAIN_T" "/rest/settings?x=/webhook/y")"
check "a hook path in the query string does not bypass [$r]" bash -c '[[ "$1" == 302* ]]' _ "$r"
check "the outpost callback path on the app host goes to the outpost, not to n8n" test "$(viab "n8n.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB
ed="$(viab "n8n.$DOMAIN_T" / "${S[@]}")"
check "with an accepted session the n8n editor is served through Traefik" bash -c 'grep -qi "n8n" <<< "$1"' _ "$ed"
st="$(viab "n8n.$DOMAIN_T" /rest/settings "${S[@]}")"
check "with an accepted session the editor's public settings show https (secure cookie, the OIDC URL on https://n8n.<domain>), the owner not yet set up, and community nodes off" bash -c 'jq -e --arg d "https://n8n.$2/" ".data.authCookie.secure == true and (.data.sso.oidc.loginUrl | startswith(\$d)) and .data.userManagement.showSetupOnFirstLoad == true and .data.communityNodesEnabled == false" <<< "$1" > /dev/null' _ "$st" "$DOMAIN_T"
h="$(viah "n8n.$DOMAIN_T" / "${S[@]}")"
check "the shared security headers are on the response (HSTS, nosniff, frame deny)" bash -c 'grep -qi "^strict-transport-security: max-age=" <<< "$1" && grep -qi "^x-content-type-options: nosniff" <<< "$1" && grep -qi "^x-frame-options: deny" <<< "$1"' _ "$h"
check "www and an unknown host are NOT served (404), even with an accepted session" test "$(via "www.$DOMAIN_T" / "${S[@]}" | cut -d' ' -f1)$(via "unknown.$DOMAIN_T" / "${S[@]}" | cut -d' ' -f1)" = 404404
docker stop n8test-auth > /dev/null
c="$(via "n8n.$DOMAIN_T" / "${S[@]}" | cut -d' ' -f1)"
check "Authentik down: the n8n editor is NOT served (forward auth fails closed: got $c)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$c"
c="$(via "n8n.$DOMAIN_T" /webhook/n8-test-path | cut -d' ' -f1)"
check "Authentik down: the webhook prefix is still answered by n8n (the allowlist is its only gate) [$c]" test "$c" = 404

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll n8n checks passed\n'
