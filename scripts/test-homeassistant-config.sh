#!/usr/bin/env bash
# test-homeassistant-config.sh - self-test of the Home Assistant stack (R17, milestone M12). Needs docker (Compose v2.24+), jq.
#
# Usage: scripts/test-homeassistant-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also boots the real image with the committed seed and watches it across Home Assistant's 5-minute "unconfirmed HTTP settings"
#              window (about 7 minutes; CI runs this)
#
# Why the long run: Home Assistant (2026.8 and later) treats an http: block in configuration.yaml as a PENDING change and, unless an admin
# confirms it in the UI within five minutes, reverts to its defaults: listening on every address, IPv6 included (seen on 2026.10.4). On the
# Pi, with the host network, that would expose it to the LAN and the internet. The seed therefore writes the settings as STABLE into
# .storage/http, and this test proves that they hold after the window. Inside a test container the proxy gateway (172.30.0.1) does not
# exist, so the seeded listen address is rewritten to the container's loopback for the run; everything else is the committed seed.
# Everything it creates is named hatest-* and removed on exit.
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
for t in docker jq; do
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

stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f hatest-ha hatest-probe > /dev/null 2>&1 || true
    docker volume rm hatest-config > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap "exit 130" INT TERM

stage="$(mktemp -d -p "${HOMEASSISTANT_TEST_TMP:-.}" .homeassistant-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })"
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole" "$stage/secrets/linkwarden" "$stage/secrets/portainer"
: > "$stage/secrets/tailscale/tailscale.env"
export APPS_ROOT="$here" DOMAIN=lab.example.test ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f homeassistant/compose.yaml --env-file config/lab.env config --format json)"
ha="$(jq -c '.services.homeassistant' <<< "$alone")"
IMAGE="$(jq -r '.image' <<< "$ha")"
printf 'image: %s\n' "$IMAGE"
lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2-; }
gw="$(lab_get PROXY_SUBNET | sed -E 's#^([0-9]+\.[0-9]+\.[0-9]+)\.0/24$#\1.1#')"
seed=homeassistant/seed
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt

echo "--- static: container definition"
check "image is the official ghcr.io/home-assistant/home-assistant YYYY.M.P pinned by digest" bash -c '[[ "$1" =~ ^ghcr\.io/home-assistant/home-assistant:20[0-9]{2}\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMAGE"
check "root compose includes homeassistant with the same image" test "$(jq -r '.services.homeassistant.image' <<< "$all")" = "$IMAGE"
check "host network (discovery, Bluetooth); not privileged; no published port" test "$(jq -c '[.network_mode, (.privileged // false), (.ports // [] | length)]' <<< "$ha")" = '["host",false,0]'
check "cap_drop ALL and only NET_ADMIN and NET_RAW (Bluetooth, as Home Assistant documents)" test "$(jq -c '[.cap_drop, (.cap_add | sort)]' <<< "$ha")" = '[["ALL"],["NET_ADMIN","NET_RAW"]]'
check "volumes: APPS_ROOT/homeassistant/config, localtime and /run/dbus read-only; no docker.sock, no /dev" test "$(jq -c '[.volumes[] | [.target, (.read_only // false)]] | sort' <<< "$ha")" = '[["/config",false],["/etc/localtime",true],["/run/dbus",true]]'
check "no devices yet (the Zigbee stick is M12b, its own commit)" test "$(jq '.devices // [] | length' <<< "$ha")" = 0
check "memory and pid limits; the health check asks the proxy gateway address" bash -c '[ "$(jq -c "[(.mem_limit != null), .pids_limit]" <<< "$1")" = "[true,512]" ] && jq -r ".healthcheck.test | join(\" \")" <<< "$1" | grep -q "http://$2:8123/"' _ "$ha" "$gw"

echo "--- static: the seed"
http="$(cat "$seed/.storage/http")"
check "seed .storage/http is version 2.2, key http, migration done, pending null (the store needs the key; null = nothing to try)" test "$(jq -c '[.version, .minor_version, .key, .data.yaml_migration_done, (.data | has("pending")), .data.pending]' <<< "$http")" = '[2,2,"http",true,true,null]'
check "STABLE settings: listen only on the proxy gateway ($gw), port 8123" test "$(jq -c '[.data.stable.server_host, .data.stable.server_port]' <<< "$http")" = "[[\"$gw\"],8123]"
check "X-Forwarded-For trusted only from the proxy subnet; IP banning on after 10 failed logins; X-Frame-Options on" test "$(jq -c '[.data.stable.use_x_forwarded_for, .data.stable.trusted_proxies, .data.stable.ip_ban_enabled, .data.stable.login_attempts_threshold, .data.stable.use_x_frame_options]' <<< "$http")" = "[true,[\"$(lab_get PROXY_SUBNET)\"],true,10,true]"
check "configuration.yaml has NO http: block (it would be a pending change that reverts), TOTP is offered, recorder trimmed" bash -c '! grep -Eq "^http:" "$1" && grep -q "type: totp" "$1" && grep -q "purge_keep_days: 10" "$1"' _ "$seed/configuration.yaml"
check "bootstrap.sh seeds both files only into an empty config directory (never overwrites)" bash -c 'grep -q "if \[ ! -e \"\$APPS_ROOT/homeassistant/config/configuration.yaml\" \] && \[ ! -e \"\$APPS_ROOT/homeassistant/config/.storage/http\" \]; then" scripts/bootstrap.sh && grep -q "homeassistant/seed/.storage/http" scripts/bootstrap.sh'
check "preflight.sh FAILs when anything but the proxy gateway listens on 8123" bash -c 'grep -q "fail ha-listen" scripts/preflight.sh'
check "bootstrap.sh unmasks Bluetooth for Home Assistant (H2 narrowed to avahi)" bash -c '. scripts/lib/host.sh && [ "${BLUETOOTH_UNITS[*]}" = "hciuart.service bluetooth.service" ] && grep -q "BLUETOOTH_UNITS" scripts/bootstrap.sh'

echo "--- static: router, tile, Dependabot"
check "ha router: the allowlist only (Home Assistant's own login, Companion app), service http://$gw:8123" bash -c 'b="$(router_block homeassistant)"; grep -q "Host(\`ha.{{ env \"DOMAIN\" }}\`)" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 1 ] && grep -q -- "- lan-allowlist$" <<< "$b" && awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://$2:8123"' _ "$rt" "$gw"
check "Homepage: the Home Assistant tile is live (Tools) and no placeholder group is left" bash -c 'awk "/^- Tools:/{f=1;next} /^- /{f=0} f" homepage/config/services.yaml | grep -q "href: https://ha.{{HOMEPAGE_VAR_DOMAIN}}/" && ! grep -q "^- Coming soon:" homepage/config/services.yaml'
check "Dependabot watches /homeassistant" grep -q -- '- /homeassistant$' .github/dependabot.yml

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Home Assistant checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
echo "--- the seed across the 5-minute window (real image)"
jq '.data.stable.server_host = ["127.0.0.1"]' "$seed/.storage/http" > "$stage/http"
cp "$seed/configuration.yaml" "$stage/configuration.yaml"
chmod 644 "$stage/http" "$stage/configuration.yaml"
docker volume rm hatest-config > /dev/null 2>&1 || true
docker volume create hatest-config > /dev/null
docker run --rm -v hatest-config:/config -v "$here:/seed:ro" --entrypoint sh "$IMAGE" -c 'mkdir -p /config/.storage && cp /seed/configuration.yaml /config/ && cp /seed/http /config/.storage/http'
docker run -d --name hatest-ha --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_RAW --memory "$(jq -r '.mem_limit' <<< "$ha")" -v hatest-config:/config "$IMAGE" > /dev/null
listeners() { docker exec hatest-ha sh -c 'netstat -tln 2>/dev/null | awk "\$4 ~ /:8123\$/ {print \$4}" | sort -u | tr "\n" " "'; }
up=""
for _ in $(seq 1 60); do
  up="$(listeners || true)"
  [ -n "$up" ] && break
  sleep 3
done
check "Home Assistant starts with cap_drop ALL plus NET_ADMIN and NET_RAW and serves its front end" bash -c 'docker exec hatest-ha curl -fsS -o /dev/null http://127.0.0.1:8123/manifest.json'
check "after start it listens ONLY on the seeded address (127.0.0.1 here, the proxy gateway on the Pi) [$up]" test "$up" = "127.0.0.1:8123 "
ip="$(docker inspect hatest-ha -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
docker run -d --name hatest-probe --entrypoint sleep "$(jq -r '.services.pihole.image' <<< "$all")" 600 > /dev/null
check "another container cannot reach it on the container's own address" bash -c '! docker exec hatest-probe wget -q -T 4 -O /dev/null "http://$1:8123/manifest.json" 2>/dev/null' _ "$ip"
echo "      (waiting through Home Assistant's 5-minute window for unconfirmed HTTP settings)"
sleep 330
after="$(listeners || true)"
check "after 5.5 minutes it STILL listens only on the seeded address: no revert to 0.0.0.0 or [::] [$after]" test "$after" = "127.0.0.1:8123 "
state="$(docker exec hatest-ha cat /config/.storage/http 2> /dev/null || true)"
check "the stored settings are still stable, with no pending change and the trusted proxy subnet" test "$(jq -c '[.data.pending, .data.stable.server_host, .data.stable.trusted_proxies]' <<< "$state" 2> /dev/null)" = "[null,[\"127.0.0.1\"],[\"$(lab_get PROXY_SUBNET)\"]]"
check "Home Assistant used the stable HTTP settings and never reverted (log), and the http integration set up" bash -c 'l="$(docker logs hatest-ha 2>&1)"; ! grep -qi "reverting to the stable config" <<< "$l" && ! grep -q "Error during setup of component http" <<< "$l"'

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Home Assistant checks passed\n'
