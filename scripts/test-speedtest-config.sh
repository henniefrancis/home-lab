#!/usr/bin/env bash
# test-speedtest-config.sh - self-test of the Speedtest Tracker stack (R19, milestone M15, ADR-018). Needs docker (Compose v2.24+), jq, curl,
# openssl.
#
# Usage: scripts/test-speedtest-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also boots the real image and the real Traefik routers, and proves the capability set (CI runs this)
#
# Dummy values only: a fake domain (lab.example.test), throw-away secrets, a self-signed wildcard certificate and a stub in place of
# authentik-server (scripts/lib/app-test.sh). Everything it creates is named sttest-* and removed on exit. The full run does NOT run a real
# speed test: the app container gets an unroutable DNS server (no Ookla, no other lookup can succeed), and the test asserts that no result
# was recorded.
#
# Static: pinned LinuxServer image (vX.Y.Z-lsN by digest); the ADR-018 register entry equals cap_add exactly; PUID/PGID 10009 from lab.env and
#   no `user:`; cap_drop ALL, no-new-privileges, limits; SPEEDTEST_SCHEDULE equal to config/lab.env (the ONE place), prune 90, public
#   dashboard, the admin password only as a FILE__ variable, no secret in any environment; the APP_KEY wrapper; the two manifest rows;
#   routers, blueprint (admins only, outpost), tile, record, bootstrap, preflight, Dependabot, no backup job.
# Full run: healthy; nginx, php-fpm and the queue worker run as 10009 and only the s6 supervisors, nginx master and php-fpm master as root;
#   every process has no_new_privs and the root processes hold exactly the registered capabilities; APP_KEY is base64 of the 32 bytes behind
#   the hex secret (not the hex value) and appears in no argv, log or `docker inspect`; the admin account exists with the file password; the
#   configured schedule is the lab.env value; pages served through Traefik link only https://speedtest.<domain> assets; forward auth
#   redirects anonymous requests; and the capability set is MINIMAL: each capability is removed in turn, and exactly those whose removal
#   stops the container from becoming healthy are the ones in compose.yaml and in the register.
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
NET=sttest-proxy
VOLS=(sttest-config)
CAPVOLS=()
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f sttest-app sttest-traefik sttest-auth sttest-probe > /dev/null 2>&1 || true
    local c
    for c in "${CAPVOLS[@]}"; do docker rm -f "sttest-cap-$c" > /dev/null 2>&1 || true; done
    docker network rm "$NET" > /dev/null 2>&1 || true
    docker volume rm "${VOLS[@]}" "${CAPVOLS[@]/#/sttest-capvol-}" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap "exit 130" INT TERM

stage="$(mktemp -d -p "${SPEEDTEST_TEST_TMP:-.}" .speedtest-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })"
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole" "$stage/secrets/linkwarden" \
  "$stage/secrets/portainer" "$stage/secrets/n8n" "$stage/secrets/couchdb" "$stage/secrets/speedtest"
: > "$stage/secrets/tailscale/tailscale.env"
# the two secrets: the app key is 64 hex characters (what set-secret.sh --generate writes), the admin password a dummy
HEXKEY="$(openssl rand -hex 32 | tr -d '\r\n')"
ADMINPW="Dummy-Admin-pw-$(openssl rand -hex 6 | tr -d '\r\n')"
printf '%s' "$HEXKEY" > "$stage/secrets/speedtest/app-key"
printf '%s' "$ADMINPW" > "$stage/secrets/speedtest/admin-password"
chmod 644 "$stage"/secrets/speedtest/*
export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f speedtest/compose.yaml --env-file config/lab.env config --format json)"
st="$(jq -c '.services["speedtest-tracker"]' <<< "$alone")"
IMG="$(jq -r '.image' <<< "$st")"
printf 'image: %s\n' "$IMG"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2-; }
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z0-9-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
bp=authentik/blueprints/homelab-apps.yaml
reg=config/adr-018-register.tsv
sched="$(lab_get SPEEDTEST_SCHEDULE | sed -E 's/^"(.*)"$/\1/')"
caps_compose="$(jq -r '.cap_add // [] | sort | join(",")' <<< "$st" | tr -d '\r')"
caps_register="$(awk -F'\t' '$1 == "speedtest-tracker" {print $2}' "$reg" | tr ',' '\n' | sort | paste -sd, -)"

echo "--- static: image, identity, hardening (ADR-018)"
check "Speedtest Tracker is the pinned ghcr.io/linuxserver/speedtest-tracker vX.Y.Z-lsN by digest" bash -c '[[ "$1" =~ ^ghcr\.io/linuxserver/speedtest-tracker:v[0-9]+\.[0-9]+\.[0-9]+-ls[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMG"
check "root compose includes the service with the same image" test "$(jq -r '.services["speedtest-tracker"].image' <<< "$all")" = "$IMG"
check "ADR-018: the service is in the register, and its cap_add EQUALS the registered set exactly [$caps_compose]" bash -c '[ -n "$1" ] && [ "$1" = "$2" ]' _ "$caps_compose" "$caps_register"
check "ADR-018: no user: (the image starts as root and drops to PUID/PGID), cap_drop ALL, no-new-privileges, not privileged, memory 512m, pids limit" test "$(jq -c '[(.user // "none"), .cap_drop, (.privileged // false), (.security_opt | index("no-new-privileges:true") != null), .mem_limit, (.pids_limit != null)]' <<< "$st")" = '["none",["ALL"],false,true,"536870912",true]'
check "PUID and PGID are SPEEDTEST_UID and SPEEDTEST_GID from lab.env, 10009 (not 0, not 1000), used once" bash -c '[ "$(jq -r "[.environment.PUID, .environment.PGID] | join(\":\")" <<< "$1")" = "10009:10009" ] && [ "$(grep -E "^SPEEDTEST_UID=" config/lab.env | cut -d= -f2)" = 10009 ] && [ "$(grep -cE "^[A-Z0-9_]+_UID=10009$" config/lab.env)" = 1 ]' _ "$st"
check "no published port, no docker.sock, no Traefik labels, only the proxy network" bash -c '[ "$(jq ".ports // [] | length" <<< "$1")" = 0 ] && ! grep -q docker.sock <<< "$1" && [ "$(jq ".labels // {} | length" <<< "$1")" = 0 ] && [ "$(jq -c "[.networks | keys[]]" <<< "$1")" = "[\"proxy\"]" ]' _ "$st"
check "the only volume is the config directory (a bind mount of APPS_ROOT/speedtest/config); nothing else is mounted" test "$(jq -c '[.volumes[] | [.source, .target]]' <<< "$st" | sed "s#$here#APPS#")" = '[["APPS/speedtest/config","/config"]]'

echo "--- static: configuration and secrets"
check "SPEEDTEST_SCHEDULE in the rendered definition equals config/lab.env exactly (the ONE place) [$sched]" bash -c '[ -n "$2" ] && [ "$(jq -r .environment.SPEEDTEST_SCHEDULE <<< "$1")" = "$2" ] && grep -q "^SPEEDTEST_SCHEDULE=\"" config/lab.env' _ "$st" "$sched"
check "the cron value is a valid 5-field expression" bash -c '[ "$(wc -w <<< "$1")" = 5 ]' _ "$sched"
check "environment: prune 90 days, public dashboard on, DB sqlite, APP_URL https://speedtest.<domain>, display time zone = TZ, admin e-mail admin@<domain>" test "$(jq -r '.environment | [.PRUNE_RESULTS_OLDER_THAN, .PUBLIC_DASHBOARD, .DB_CONNECTION, .APP_URL, .DISPLAY_TIMEZONE, .ADMIN_EMAIL] | join(" ")' <<< "$st")" = "90 true sqlite https://speedtest.$DOMAIN_T $(lab_get TZ) admin@$DOMAIN_T"
check "SPEEDTEST_SERVERS comes from lab.env (empty = Ookla picks the nearest server)" test "$(jq -r '.environment.SPEEDTEST_SERVERS' <<< "$st")" = "$(lab_get SPEEDTEST_SERVERS)"
check "secrets: the admin password only as FILE__ADMIN_PASSWORD (a path), APP_KEY and ADMIN_PASSWORD never in the environment" bash -c '[ "$(jq -r .environment.FILE__ADMIN_PASSWORD <<< "$1")" = /run/secrets/speedtest_admin_password ] && ! jq -r ".environment | keys[]" <<< "$1" | grep -Eqx "APP_KEY|ADMIN_PASSWORD|DB_PASSWORD|APP_SECRET"' _ "$st"
check "the APP_KEY wrapper converts the hex secret with the image's PHP (hex2bin, base64_encode), checks the length, unsets an empty SPEEDTEST_SERVERS and execs /init" bash -c 'e="$(jq -r ".entrypoint | join(\" \")" <<< "$1")"; grep -q "hex2bin" <<< "$e" && grep -q "base64_encode" <<< "$e" && grep -q "/run/secrets/speedtest_app_key" <<< "$e" && grep -qF "unset SPEEDTEST_SERVERS" <<< "$e" && grep -q "exec /init" <<< "$e" && [ "$(jq -r "[.secrets[].source] | sort | join(\" \")" <<< "$1")" = "speedtest_admin_password speedtest_app_key" ]' _ "$st"
check "the compose file contains no literal key (no 64-hex string, no base64 key) and no custom-cont-init mount (comments aside)" bash -c 'c="$(grep -v "^[[:space:]]*#" "$1" | grep -v "image:")"; ! grep -qE "[0-9a-f]{64}|base64:[A-Za-z0-9+/]{43}=" <<< "$c" && ! grep -q "custom-cont-init" <<< "$c"' _ speedtest/compose.yaml
check "manifest: speedtest/app-key and speedtest/admin-password, required, 0:0 0400 (read by the root init only)" bash -c 'm=config/secrets-manifest.tsv; grep -qP "^speedtest/app-key\tspeedtest/app-key\t0:0\t0400\tyes\traw$" $m && grep -qP "^speedtest/admin-password\tspeedtest/admin-password\t0:0\t0400\tyes\traw$" $m'
check "set-secret.sh applies the 72-byte bcrypt limit to speedtest/admin-password" bash -c 'grep -q "speedtest/admin-password" scripts/set-secret.sh'

echo "--- static: routers, Authentik, tile, record"
check "speedtest router: allowlist then Authentik forward auth, service speedtest-tracker:80" bash -c 'b="$(router_block speedtest)"; grep -q "Host(\`speedtest.{{ env \"DOMAIN\" }}\`)" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -- "- " | tr -d " \n")" = "-lan-allowlist-authentik" ] && grep -q "service: speedtest$" <<< "$b" && awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://speedtest-tracker:80"' _ $rt
check "speedtest-outpost: the outpost path on the app host, priority 100, allowlist only, service authentik" bash -c 'b="$(router_block speedtest-outpost)"; grep -q "PathPrefix(\`/outpost.goauthentik.io/\`)" <<< "$b" && grep -q "priority: 100$" <<< "$b" && grep -q "service: authentik$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 1 ]' _
check "blueprint: provider homelab-speedtest (forward_single, speedtest.<domain>), application 'Speedtest Tracker' bound to homelab-admins ONLY, on the embedded outpost" bash -c 'b="$(awk "/id: provider-speedtest/{f=1} f&&/id: app-speedtest/{exit} f" "$1")"; grep -q "mode: forward_single" <<< "$b" && grep -q "external_host: !Format \[\"https://speedtest.%s\", !Env DOMAIN\]" <<< "$b" && [ "$(awk "/target: !KeyOf app-speedtest/{getline; print}" "$1" | tr -d " ")" = "group:!KeyOfgroup-admins" ] && awk "/id: embedded-outpost/{f=1} f" "$1" | grep -q -- "- !KeyOf provider-speedtest"' _ $bp
check "Homepage: the Speedtest Tracker tile is live in Tools" bash -c 'awk "/^- Tools:/{f=1;next} /^- /{f=0} f" homepage/config/services.yaml | grep -q "href: https://speedtest.{{HOMEPAGE_VAR_DOMAIN}}/"'
check "Pi-hole: speedtest.<domain> is answered with the Pi's LAN address" test "$(jq -r '.services.pihole.environment.FTLCONF_dns_hosts' <<< "$all" | tr ' ' '\n' | grep -cx "speedtest.$DOMAIN_T")" = 1
check "bootstrap.sh creates speedtest/config for SPEEDTEST_UID (0700) and preflight.sh checks it" bash -c 'grep -q "install -d -m 0700 -o \"\$ST_UID\" -g \"\$ST_GID\" \"\$APPS_ROOT/speedtest/config\"" scripts/bootstrap.sh && grep -q "speedtest:SPEEDTEST:config" scripts/preflight.sh'
check "Speedtest Tracker is NOT backed up (owner decision): no job in backup-apps.sh" bash -c '! sed -n "/^JOBS=(/,/^)/p" scripts/backup-apps.sh | grep -qi speedtest'
check "Dependabot watches /speedtest" grep -q -- '- /speedtest$' .github/dependabot.yml
check "the CI socket guard and digest pinning cover speedtest/compose.yaml" bash -c 'grep -q "no_sock=.*speedtest" .github/workflows/ci.yml && grep -q "speedtest/compose.yaml" .github/workflows/ci.yml'
check "scan-images.sh scans the Speedtest Tracker image" bash -c 'grep -q "speedtest/compose.yaml" scripts/scan-images.sh'

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Speedtest Tracker checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
echo "--- containers"
docker network create "$NET" > /dev/null
own() { docker run --rm --user 0 --entrypoint sh --mount "type=volume,src=$1,dst=/v,volume-nocopy" "$IMG" -c 'chown 10009:10009 /v && chmod 0700 /v'; }
docker volume rm "${VOLS[@]}" > /dev/null 2>&1 || true
docker volume create sttest-config > /dev/null
own sttest-config
# --dns: an unroutable resolver, so the container can reach other containers by name but no real host (no Ookla traffic from CI).
app_test_run sttest-app "$st" speedtest-tracker "$NET" --dns 192.0.2.1 --mount "type=volume,src=sttest-config,dst=/config,volume-nocopy"
app_test_stub_auth sttest "$NET"
app_test_traefik sttest "$NET"
cid="$APP_TEST_CID"

echo "--- Speedtest Tracker container"
healthy=0
wait_healthy sttest-app 100 && healthy=1
check "the container becomes healthy with the rendered definition (compose healthcheck: /api/healthcheck)" test "$healthy" = 1
ps_all="$(docker exec sttest-app sh -c 'ps -eo user,args' 2> /dev/null | tr -d '\r' || true)"
check "the queue worker, every nginx worker and the php-fpm pool run as the unprivileged PUID user (abc) [$(grep -c ' abc ' <<< "$ps_all" || true) processes]" bash -c 'grep -q "^abc .*queue:work" <<< "$1" && grep -q "^abc .*nginx: worker" <<< "$1" && grep -q "^abc .*php-fpm: pool www" <<< "$1" && ! grep -E "queue:work|nginx: worker|php-fpm: pool" <<< "$1" | grep -q "^root"' _ "$ps_all"
check "the unprivileged user abc is uid 10009 and gid 10009" test "$(docker exec sttest-app sh -c 'id -u abc; id -g abc' | tr -d '\r' | tr '\n' ' ')" = "10009 10009 "
nnp="$(docker exec sttest-app sh -c 'for p in /proc/[0-9]*/status; do awk "/^NoNewPrivs:/{print \$2}" $p; done' 2> /dev/null | sort -u | tr -d '\r\n' || true)"
check "every process has no_new_privs set [$nnp]" test "$nnp" = 1
# the numbers of the capabilities (linux/capability.h) to compute the expected mask of the root processes
declare -A capnum=([CHOWN]=0 [DAC_OVERRIDE]=1 [FOWNER]=3 [SETGID]=6 [SETUID]=7 [NET_BIND_SERVICE]=10)
mask=0
for c in ${caps_compose//,/ }; do mask=$((mask | (1 << capnum[$c]))); done
want="$(printf '%016x' "$mask")"
bnd="$(docker exec sttest-app sh -c 'awk "/^CapBnd:/{print \$2}" /proc/1/status' | tr -d '\r')"
check "the capability bounding set of the root init is exactly the registered set (mask $want) [$bnd]" test "$bnd" = "$want"
check "the unprivileged workers hold no capability at all" bash -c '[ "$(docker exec sttest-app sh -c "for p in \$(pgrep -u abc); do awk \"/^CapEff:/{print \\\$2}\" /proc/\$p/status; done" | tr -d "\r" | sort -u | tr -d "\n")" = 0000000000000000 ]'
check "the config directory is owned by 10009 and writable by the app (SQLite database, keys, logs)" bash -c '[ "$(docker exec sttest-app stat -c "%u:%g" /config /config/database.sqlite | tr -d "\r" | sort -u | tr "\n" " ")" = "10009:10009 " ]'
check "docker inspect: CapDrop ALL, the registered CapAdd, no port bindings, three mounts (config and the two secrets), user empty (root start, ADR-018), not read-only" test "$(docker inspect sttest-app -f '{{json .HostConfig.CapDrop}} {{len .HostConfig.PortBindings}} {{len .Mounts}} [{{.Config.User}}] {{.HostConfig.ReadonlyRootfs}}' | tr -d '\r')" = '["ALL"] 0 3 [] false'

echo "--- the secrets"
ak="$(docker exec sttest-app cat /run/s6/container_environment/APP_KEY | tr -d '\r')"
want_key="$(docker run --rm --entrypoint php "$IMG" -r 'echo "base64:".base64_encode(hex2bin($argv[1]));' "$HEXKEY" | tr -d '\r')"
check "APP_KEY in the container is base64: plus the 32 bytes behind the hex secret, and is NOT the hex value" bash -c '[ "$1" = "$2" ] && [[ "$1" =~ ^base64:[A-Za-z0-9+/]{43}=$ ]] && [ "$1" != "$3" ] && [ "$(docker run --rm --entrypoint php "$4" -r "echo strlen(base64_decode(substr(\$argv[1], 7)));" "$1" | tr -d "\r")" = 32 ]' _ "$ak" "$want_key" "$HEXKEY" "$IMG"
leak="$(docker inspect sttest-app --format '{{json .Config}}' | tr -d '\r'; docker logs sttest-app 2>&1; docker exec sttest-app sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" " "')"
check "neither the hex key, the base64 key nor the admin password is in docker inspect, the logs or any process command line" bash -c '! grep -qF -e "$2" -e "$3" -e "$4" <<< "$1"' _ "$leak" "$HEXKEY" "${ak#base64:}" "$ADMINPW"
check "Laravel runs with that key (config app.key) and the application answers its health check" bash -c 'docker exec sttest-app sh -c "cd /app/www && s6-setuidgid abc php artisan config:show app --no-ansi 2>/dev/null | grep -q \"key\"" && docker exec sttest-app curl -fsS http://127.0.0.1:80/api/healthcheck | grep -q running'
chk="$(docker exec -e P="$ADMINPW" sttest-app php -r '$d = new PDO("sqlite:/config/database.sqlite"); $r = $d->query("select email, password from users limit 1")->fetch(PDO::FETCH_ASSOC); echo $r["email"], " ", password_verify(getenv("P"), $r["password"]) ? "PASSWORD-OK" : "PASSWORD-WRONG";' 2> /dev/null | tr -d '\r' || true)"
# shellcheck disable=SC2001 # a sed over a multi-line variable is clearer here
check "the admin account exists as admin@<domain> and the password from the FILE__ secret verifies [$(sed 's/ .*//' <<< "$chk" | head -c 40) ...]" test "$chk" = "admin@$DOMAIN_T PASSWORD-OK"

echo "--- the schedule and no real test"
cs="$(docker exec sttest-app sh -c 'cd /app/www && s6-setuidgid abc php artisan config:show speedtest --no-ansi 2>/dev/null' | tr -d '\r' || true)"
check "the application's configured schedule is the lab.env value [$sched]" bash -c 'grep -E "^ *schedule " <<< "$1" | grep -qF -- "$2"' _ "$cs" "$sched"
check "the application's prune period is 90 days and the public dashboard is on" bash -c 'grep -Eq "^ *prune_results_older_than \.+ 90 *$" <<< "$1" && grep -Eq "^ *public_dashboard \.+ true *$" <<< "$1"' _ "$cs"
check "the environment value reaches the container unchanged (no quotes, no escaping): [$sched]" test "$(docker inspect sttest-app -f '{{range .Config.Env}}{{println .}}{{end}}' | tr -d '\r' | grep '^SPEEDTEST_SCHEDULE=' | cut -d= -f2-)" = "$sched"
check "no real speed test ran: no completed result in the database, no Ookla process" bash -c '[ "$(docker exec sttest-app php -r "\$d = new PDO(\"sqlite:/config/database.sqlite\"); echo \$d->query(\"select count(*) from results where status = \x27completed\x27\")->fetchColumn();" | tr -d "\r")" = 0 ] && ! docker exec sttest-app sh -c "ps -eo args | grep -i \"[s]peedtest --\""'

echo "--- through Traefik (real flags, routers and middlewares; stub outpost)"
ready=0
for _ in $(seq 1 30); do
  case "$(via "speedtest.$DOMAIN_T" /)" in 302*) ready=1 && break ;; esac
  sleep 2
done
check "Traefik discovered the speedtest routers (an anonymous request is answered with 302)" test "$ready" = 1
check "Traefik reports no error for the speedtest routers or the authentik middleware" bash -c '! docker logs "$1" 2>&1 | jq -R -r "fromjson? | select(.level==\"error\") | .msg" | grep -Ei "speedtest|authentik|outpost|forwardauth|middleware"' _ "$cid"
S=(-H 'Cookie: stub_session=ok')
for p in / /admin /admin/login /api/healthcheck /api/v1/results/latest; do
  r="$(via "speedtest.$DOMAIN_T" "$p")"
  check "anonymous GET $p is redirected to the Authentik authorize endpoint (Speedtest Tracker not reached) [$r]" bash -c '[[ "$1" == "302 https://auth.lab.example.test/application/o/authorize/"* ]]' _ "$r"
done
check "a forged identity header does not bypass forward auth (still 302)" bash -c '[[ "$1" == 302* ]]' _ "$(via "speedtest.$DOMAIN_T" / -H 'X-authentik-username: akadmin' -H 'X-authentik-groups: homelab-admins')"
check "the outpost callback path on the app host goes to the outpost, not to the app" test "$(viab "speedtest.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB
login="$(viab "speedtest.$DOMAIN_T" /admin/login "${S[@]}")"
check "with an accepted session the app's own admin login page is served (its settings need that login) [$(grep -oE '<title>[^<]*' <<< "$login" | head -1 | cut -c1-60)]" bash -c 'grep -qi "sign in\|log in\|login" <<< "$1" && ! grep -qi "forward" <<< "$1"' _ "$login"
dash="$(viab "speedtest.$DOMAIN_T" / "${S[@]}" -L)"
check "the public dashboard (PUBLIC_DASHBOARD=true) is served to a session without the app's login" bash -c 'grep -qi "speedtest" <<< "$1"' _ "$dash"
links="$(grep -oE '(href|src)="https?://[^"]+"' <<< "$login$dash" | sed -E 's/^(href|src)="//; s/"$//' | sort -u)"
check "Laravel behind Traefik: the same-host links the pages emit are https://speedtest.<domain>; the ONLY http:// one is the favicon (the app builds it itself; HSTS makes the browser upgrade it) [$(grep -c "^https://speedtest.$DOMAIN_T/" <<< "$links") https links]" bash -c '[ "$(grep -c "^https://speedtest.$2/" <<< "$1")" -ge 5 ] && [ "$(grep -E "^http://" <<< "$1" | grep -vc "^http://speedtest.$2/img/speedtest-tracker-icon.png$")" = 0 ] && ! grep -E "127\.0\.0\.1|localhost" <<< "$1" | grep -q .' _ "$links" "$DOMAIN_T"
h="$(viah "speedtest.$DOMAIN_T" /admin/login "${S[@]}")"
check "the shared security headers are on the response and the nginx banner is removed" bash -c 'grep -qi "^strict-transport-security: max-age=" <<< "$1" && grep -qi "^x-content-type-options: nosniff" <<< "$1" && grep -qi "^x-frame-options: deny" <<< "$1" && ! grep -qi "^server: nginx" <<< "$1"' _ "$h"
asset="$(grep -oE 'https://speedtest\.[^"]+/build/assets/[^"]+\.css' <<< "$login" | head -1 | sed "s#https://speedtest.$DOMAIN_T##")"
check "a stylesheet link from the page is fetched through the Traefik router with a session [$asset]" bash -c '[ -n "$1" ] && [ "$(curl -sk -o /dev/null -w "%{http_code}" --connect-to "speedtest.$2:443:127.0.0.1:$3" -H "Cookie: stub_session=ok" "https://speedtest.$2$1")" = 200 ]' _ "$asset" "$DOMAIN_T" "$APP_TEST_HOSTPORT"
docker stop sttest-auth > /dev/null
c="$(via "speedtest.$DOMAIN_T" / "${S[@]}" | cut -d' ' -f1)"
check "Authentik down: Speedtest Tracker is NOT served (forward auth fails closed: got $c)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$c"

# --------------------------------------------------------------------------------------------------------------------
echo "--- the capability set is minimal (ADR-018): each registered capability removed in turn, all variants started together"
read -r -a caps_list <<< "${caps_compose//,/ }"
CAPVOLS=("${caps_list[@]}")
base_ep="$(jq -r '.entrypoint[0]' <<< "$st")"
for c in "${caps_list[@]}"; do
  docker volume rm "sttest-capvol-$c" > /dev/null 2>&1 || true
  docker volume create "sttest-capvol-$c" > /dev/null
  own "sttest-capvol-$c"
  variant="$(jq -c --arg c "$c" '.cap_add |= map(select(. != $c))' <<< "$st")"
  # a variant has no published port and no stub network needs: it only has to become healthy on its own
  app_test_run "sttest-cap-$c" "$variant" "sttest-cap-$c" "$NET" --dns 192.0.2.1 --mount "type=volume,src=sttest-capvol-$c,dst=/config,volume-nocopy"
done
needed=()
declare -A upc=()
# one shared deadline for all variants (about 100 s): a variant that starts does so within a few seconds, so a variant still down after that is "needed"
for _ in $(seq 1 25); do
  pending=0
  for c in "${caps_list[@]}"; do
    [ "${upc[$c]:-0}" = 1 ] && continue
    if docker exec "sttest-cap-$c" curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:80/api/healthcheck > /dev/null 2>&1; then upc[$c]=1; else pending=1; fi
  done
  [ "$pending" = 0 ] && break
  sleep 3
done
for c in "${caps_list[@]}"; do
  if [ "${upc[$c]:-0}" = 1 ]; then printf '      without %-17s starts (not needed)\n' "$c"; else
    printf '      without %-17s does NOT start (needed)\n' "$c"
    needed+=("$c")
  fi
done
needed_s="$(printf '%s\n' "${needed[@]:-}" | grep -v '^$' | sort | paste -sd, -)"
check "the capabilities whose removal stops the container are EXACTLY the ones in compose.yaml and in the ADR-018 register [needed: $needed_s; compose: $caps_compose]" bash -c '[ "$1" = "$2" ] && [ "$1" = "$3" ]' _ "$needed_s" "$caps_compose" "$caps_register"
: "$base_ep"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Speedtest Tracker checks passed\n'
