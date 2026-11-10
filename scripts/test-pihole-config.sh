#!/usr/bin/env bash
# test-pihole-config.sh - self-test of the Pi-hole stack (R17, milestone M8). Needs docker (Compose v2.24+), jq, curl, openssl.
#
# Usage: scripts/test-pihole-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also boots the real image and the real Traefik routers (CI runs this; about two minutes on a runner)
#
# Dummy values only: a fake domain (lab.example.test), a fake LAN address (10.0.0.2), a throw-away password, a self-signed wildcard
# certificate and a stub in place of the Authentik outpost (the NGINX image already pinned in it-tools/Dockerfile). Nothing is sent to
# ACME, AWS or any real host; the only outbound traffic is Pi-hole's own upstream lookups and blocklist download. Everything it creates
# is named phtest-* and removed on exit.
#
# Static: pinned image; capabilities exactly the documented set (no NET_ADMIN, NET_RAW, SYS_TIME, SYS_NICE); DNS published on IPv4 only
#   and nothing else published; proxy network only; PIHOLE_UID 10006 (not root, not 1000); the password only from a secret file;
#   Quad9 upstreams from lab.env, DNSSEC on, no DHCP or NTP; the lab-name list equals every Traefik host plus bg-traefik and never the
#   apex or www; the SSM config parameter, manifest rows, bootstrap directory, preflight check, routers, Authentik entries, tile, Dependabot.
# Full run: Pi-hole starts healthy with that definition; FTL runs as 10006 with only NET_BIND_SERVICE effective; every lab name answers
#   the LAN address and nothing else; the apex and www do not; the web password works and a wrong one does not; the password is not in
#   the environment; through the REAL Traefik flags, routers and middlewares the web UI is behind forward auth and fails closed.
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
unset PROXY_SUBNET AUTHENTIK_AUTH_SUBNET APPS_ROOT DOMAIN AUTHENTIK_UID AUTHENTIK_GID AUTHENTIK_PG_UID AUTHENTIK_PG_GID HOMEPAGE_UID HOMEPAGE_GID TRAEFIK_UID TRAEFIK_GID ITTOOLS_UID ITTOOLS_GID PIHOLE_UID PIHOLE_GID PIHOLE_UPSTREAMS PI_LAN_IP TZ

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
LAN_T=10.0.0.2
PW_T="phtest-$(openssl rand -hex 12)"
NET_PROXY=phtest-proxy
# A named volume, not a bind mount, for /etc/pihole: FTL makes its files owned by 10006, which the runner user could not delete.
VOL_ETC=phtest-etc-pihole
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f phtest-pihole phtest-traefik phtest-auth > /dev/null 2>&1 || true
    docker network rm "$NET_PROXY" > /dev/null 2>&1 || true
    docker volume rm "$VOL_ETC" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT

stage="$(mktemp -d -p "${PIHOLE_TEST_TMP:-.}" .pihole-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })" # a path docker.exe understands under Git Bash, plain pwd elsewhere
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole"
: > "$stage/secrets/tailscale/tailscale.env"
printf '%s' "$PW_T" > "$stage/secrets/pihole/admin-password"
chmod 644 "$stage/secrets/pihole/admin-password"

export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP="$LAN_T"
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f pihole/compose.yaml --env-file config/lab.env config --format json)"
ph="$(jq -c '.services.pihole' <<< "$alone")"
IMAGE="$(jq -r '.image' <<< "$ph")"
printf 'image: %s\n' "$IMAGE"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2-; }
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
bp=authentik/blueprints/homelab-apps.yaml
env_of() { jq -r --arg k "$1" '.environment[$k] // ""' <<< "$ph"; }

echo "--- static: container definition"
check "image is a pinned pihole/pihole YYYY.MM.N by digest (official image, not latest)" bash -c '[[ "$1" =~ ^pihole/pihole:20[0-9]{2}\.[0-9]{2}\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMAGE"
check "root compose includes pihole, and --only pihole renders the same service" test "$(jq -r '.services.pihole.image' <<< "$all")" = "$IMAGE"
check "cap_drop ALL and cap_add exactly the documented set (CHOWN DAC_OVERRIDE FOWNER NET_BIND_SERVICE SETFCAP SETGID SETUID)" test "$(jq -c '[.cap_drop, (.cap_add | sort)]' <<< "$ph")" = '[["ALL"],["CHOWN","DAC_OVERRIDE","FOWNER","NET_BIND_SERVICE","SETFCAP","SETGID","SETUID"]]'
check "no NET_ADMIN, NET_RAW, SYS_TIME, SYS_NICE (no DHCP, no NTP) and not privileged" bash -c '! jq -r ".cap_add[]" <<< "$1" | grep -Eq "NET_ADMIN|NET_RAW|SYS_TIME|SYS_NICE" && [ "$(jq -r ".privileged // false" <<< "$1")" = false ]' _ "$ph"
check "DNS published on IPv4 0.0.0.0 only, UDP and TCP 53, nothing else published (no web port, no DHCP)" test "$(jq -c '[.ports[] | [.host_ip, .published, .target, .protocol]] | sort' <<< "$ph")" = '[["0.0.0.0","53",53,"tcp"],["0.0.0.0","53",53,"udp"]]'
check "on the proxy network ONLY (external)" test "$(jq -c '[.networks | keys[]]' <<< "$ph")" = '["proxy"]'
check "runs FTL as PIHOLE_UID:PIHOLE_GID = 10006:10006 (the image default 1000 is the login user)" test "$(env_of PIHOLE_UID):$(env_of PIHOLE_GID):$(lab_get PIHOLE_UID):$(lab_get PIHOLE_GID)" = "10006:10006:10006:10006"
check "the uid is not used by any other service in lab.env" test "$(grep -cE '^[A-Z_]+_UID=10006$' config/lab.env)" = 1
check "the web password only from the secret file (WEBPASSWORD_FILE), never an environment value" bash -c '[ "$(jq -r ".environment.WEBPASSWORD_FILE" <<< "$1")" = pihole_admin_password ] && ! jq -r ".environment | keys[]" <<< "$1" | grep -qi "api_password\|WEBPASSWORD$" && jq -e ".secrets[] | select(.source == \"pihole_admin_password\")" <<< "$1"' _ "$ph"
check "the secret file is APPS_ROOT/secrets/pihole/admin-password" bash -c 'jq -r ".secrets.pihole_admin_password.file" <<< "$1" | tr "\\\\" / | grep -q "/secrets/pihole/admin-password$"' _ "$alone"
check "upstreams are Quad9 from lab.env (owner decision 2026-11-10)" test "$(env_of FTLCONF_dns_upstreams)|$(lab_get PIHOLE_UPSTREAMS)" = "9.9.9.9;149.112.112.112|9.9.9.9;149.112.112.112"
check "DNSSEC on, domainNeeded and bogusPriv on, DHCP and NTP off, nice disabled, 7 days of query history" test "$(env_of FTLCONF_dns_dnssec)$(env_of FTLCONF_dns_domainNeeded)$(env_of FTLCONF_dns_bogusPriv)|$(env_of FTLCONF_dhcp_active)$(env_of FTLCONF_ntp_ipv4_active)$(env_of FTLCONF_ntp_ipv6_active)$(env_of FTLCONF_ntp_sync_active)|$(env_of FTLCONF_misc_nice)|$(env_of FTLCONF_database_maxDBdays)" = "truetruetrue|falsefalsefalsefalse|-999|7"
check "listening mode ALL (bridge network), web server on port 80 only (no self-signed HTTPS inside)" test "$(env_of FTLCONF_dns_listeningMode)|$(env_of FTLCONF_webserver_port)" = "ALL|80"
hosts="$(env_of FTLCONF_dns_hosts)"
check "the lab-name entry starts with the Pi's LAN address from runtime.env (PI_LAN_IP)" test "$(cut -d' ' -f1 <<< "$hosts")" = "$LAN_T"
names="$(tr ' ' '\n' <<< "$hosts" | tail -n +2 | sed '/^$/d' | sort)"
router_hosts="$( { grep -ho 'Host(`[a-z0-9-]*\.{{ env "DOMAIN" }}`)' traefik/dynamic/*.yml traefik/breakglass/*.yml | sed -E 's/Host\(`([a-z0-9-]+)\..*/\1/'; } | sort -u | sed "s/\$/.$DOMAIN_T/")"
check "every Traefik host (routers and the break-glass drop-in) is in the lab-name list" bash -c 'for h in $2; do grep -qx "$h" <<< "$1" || exit 1; done' _ "$names" "$router_hosts"
check "the list never has the apex or www (R5) and only subdomains of the lab domain" bash -c '! grep -Eqx "(www\.)?lab\.example\.test" <<< "$1" && ! grep -Evq "^[a-z0-9-]+\.lab\.example\.test$" <<< "$1"' _ "$names"
check "the list covers the planned R17 hosts too (links, netdata, portainer, ha)" bash -c 'for h in links netdata portainer ha; do grep -qx "$h.lab.example.test" <<< "$1" || exit 1; done' _ "$names"
check "memory 256M, pids 128; /tmp and /var/log/pihole are tmpfs (SD-card wear)" test "$(jq -c '[.mem_limit, .pids_limit, (.tmpfs | sort)]' <<< "$ph")" = '["268435456",128,["/tmp","/var/log/pihole"]]'
check "the only volume is APPS_ROOT/pihole/etc-pihole at /etc/pihole (no docker.sock)" bash -c '[ "$(jq -r ".volumes | length" <<< "$1")" = 1 ] && jq -r ".volumes[0].source" <<< "$1" | tr "\\\\" / | grep -q "/pihole/etc-pihole$" && [ "$(jq -r ".volumes[0].target" <<< "$1")" = /etc/pihole ] && ! grep -q docker.sock <<< "$1"' _ "$ph"
check "no Traefik labels (routers are files, SEC-H2)" test "$(jq '.labels // {} | length' <<< "$ph")" = 0

echo "--- static: SSM, manifest, host scripts"
check "terraform/edge: variable pi_lan_ipv4 (null default, RFC 1918 only) mirrored to config/pi-lan-ip, no DNS record from it" bash -c 'grep -q "variable \"pi_lan_ipv4\"" terraform/edge/variables.tf && grep -q "\"config/pi-lan-ip\" = var.pi_lan_ipv4" terraform/edge/ssm.tf && ! grep -q "pi_lan_ipv4" terraform/edge/records.tf terraform/edge/route53.tf'
check "manifest: config/pi-lan-ip -> runtime.env PI_LAN_IP (required), pihole/admin-password -> 10006:10006 0400 (required)" bash -c 'grep -qP "^config/pi-lan-ip\truntime.env\t0:0\t0600\tyes\tenv:PI_LAN_IP$" config/secrets-manifest.tsv && grep -qP "^pihole/admin-password\tpihole/admin-password\t10006:10006\t0400\tyes\traw$" config/secrets-manifest.tsv'
check "bootstrap.sh creates APPS_ROOT/pihole/etc-pihole with PIHOLE_UID and refuses 0/1000 for it" bash -c 'grep -q "PH_UID=.*PIHOLE_UID" scripts/bootstrap.sh && grep -q "pihole/etc-pihole" scripts/bootstrap.sh && grep -q "\"\$PH_UID\" \"\$PH_GID\"; do" scripts/bootstrap.sh'
check "preflight.sh fails on an IPv6 DNS listener and checks the Pi-hole data directory and ids" bash -c 'grep -q "fail dns-ipv6" scripts/preflight.sh && grep -q "pihole-data" scripts/preflight.sh && grep -q "PIHOLE_UID PIHOLE_GID; do" scripts/preflight.sh'

echo "--- static: routers, Authentik, Homepage, Dependabot"
check "pihole router: pihole.<domain>, websecure, lan-allowlist then authentik, service pihole" bash -c 'b="$(router_block pihole)"; grep -q "Host(\`pihole.{{ env \"DOMAIN\" }}\`)" <<< "$b" && grep -q "service: pihole$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 2 ] && grep -A1 "middlewares:" <<< "$b" | grep -q -- "- lan-allowlist" && grep -q -- "- authentik$" <<< "$b"' _
check "pihole service points at http://pihole:80" bash -c 'awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://pihole:80"' _ $rt
check "pihole-outpost router has the same shape as the Traefik dashboard's" bash -c 'diff <(router_block dashboard-outpost | grep -Ev "rule:|^ *#|^$") <(router_block pihole-outpost | grep -Ev "rule:|^ *#|^$") && router_block pihole-outpost | grep -q "pihole.{{ env"' _
check "blueprint: provider homelab-pihole for https://pihole.<domain>, application pihole bound to homelab-admins, served by the outpost" bash -c 'grep -q "name: homelab-pihole" "$1" && grep -q "external_host: !Format \[\"https://pihole.%s\", !Env DOMAIN\]" "$1" && awk "/target: !KeyOf app-pihole/{f=1} f&&/group:/{print; exit}" "$1" | grep -q group-admins && awk "/managed: goauthentik.io\/outposts\/embedded/{f=1} f" "$1" | grep -q -- "- !KeyOf provider-pihole"' _ $bp
check "Homepage: the Pi-hole tile is live in Tools and opens /admin/" bash -c 'awk "/^- Tools:/{f=1;next} /^- /{f=0} f" homepage/config/services.yaml | grep -q "href: https://pihole.{{HOMEPAGE_VAR_DOMAIN}}/admin/" && ! awk "/^- Coming soon:/{f=1} f" homepage/config/services.yaml | grep -q "pihole\."'
check "Dependabot docker-compose watches /pihole" grep -q -- '- /pihole$' .github/dependabot.yml

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Pi-hole checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
# Containers: the REAL Pi-hole definition, the REAL Traefik flags, routers and middlewares, a stub outpost.
# --------------------------------------------------------------------------------------------------------------------
echo "--- containers"
docker network create "$NET_PROXY" > /dev/null
docker volume rm "$VOL_ETC" > /dev/null 2>&1 || true
args=(--name phtest-pihole --network "$NET_PROXY" --network-alias pihole --hostname pihole --memory "$(jq -r '.mem_limit' <<< "$ph")"
  --pids-limit "$(jq -r '.pids_limit' <<< "$ph")" --cap-drop ALL
  --mount "type=bind,source=$here/secrets/pihole/admin-password,target=/run/secrets/pihole_admin_password,readonly"
  --mount "type=volume,source=$VOL_ETC,target=/etc/pihole")
while IFS= read -r l; do args+=(--cap-add "$l"); done < <(jq -r '.cap_add[]' <<< "$ph" | tr -d '\r')
while IFS= read -r l; do args+=(--tmpfs "$l"); done < <(jq -r '.tmpfs[]' <<< "$ph" | tr -d '\r')
while IFS= read -r l; do args+=(-e "$l"); done < <(jq -r '.environment | to_entries[] | "\(.key)=\(.value)"' <<< "$ph" | tr -d '\r')
docker run -d "${args[@]}" "$IMAGE" > /dev/null

stub_img="$(awk '$1=="FROM" && $2 ~ /^nginxinc\/nginx-unprivileged:/ {print $2}' it-tools/Dockerfile)"
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
acid="$(docker create --name phtest-auth --network "$NET_PROXY" --network-alias authentik-server "$stub_img" nginx -g 'daemon off;')"
docker cp "$here/stub.conf" "$acid:/etc/nginx/conf.d/default.conf"
docker start phtest-auth > /dev/null

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
cid="$(docker create --name phtest-traefik --network "$NET_PROXY" -p 127.0.0.1::443 -e DOMAIN="$DOMAIN_T" --tmpfs /letsencrypt "$timage" "${flags[@]}")"
chmod 644 "$stage/tr/dynamic/test-k.pem"
docker cp "$here/tr/." "$cid:/etc/traefik"
docker start "$cid" > /dev/null

echo "--- Pi-hole container"
healthy=0
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' phtest-pihole 2> /dev/null)" = healthy ] && {
    healthy=1
    break
  }
  sleep 3
done
check "Pi-hole reports healthy with the hardened definition" test "$healthy" = 1
px() { docker exec phtest-pihole "$@"; }
ftl_status="$(px sh -c 'cat /proc/$(pidof pihole-FTL)/status' 2> /dev/null || true)"
check "FTL (DNS and web server) runs as uid and gid 10006, not root" bash -c 'grep -Eq "^Uid:\s+10006\s+10006\s+10006\s+10006$" <<< "$1" && grep -Eq "^Gid:\s+10006\s+10006\s+10006\s+10006$" <<< "$1"' _ "$ftl_status"
check "FTL's effective capabilities are exactly NET_BIND_SERVICE (0x400)" bash -c 'grep -Eq "^CapEff:\s+0000000000000400$" <<< "$1"' _ "$ftl_status"
check "FTL's bounding set is the compose cap_add list and nothing more (0x800004cb)" bash -c 'grep -Eq "^CapBnd:\s+00000000800004cb$" <<< "$1"' _ "$ftl_status"
check "the pihole user in the container is 10006 (PIHOLE_UID applied), and /etc/pihole is owned by it" test "$(px sh -c 'id -u pihole; stat -c %u:%g /etc/pihole')" = "$(printf '10006\n10006:10006')"
check "the password is not in the container environment (only the secret file name is)" bash -c '! docker inspect phtest-pihole -f "{{json .Config.Env}}" | grep -qF "$1"' _ "$PW_T"
dq() { px dig +short +time=3 +tries=1 @127.0.0.1 "$@" 2> /dev/null || true; }
for n in $names; do
  check "DNS: $n answers the LAN address $LAN_T" test "$(dq "$n" A)" = "$LAN_T"
done
check "DNS: the lab names have no AAAA answer (no IPv6 leak)" test -z "$(dq "auth.$DOMAIN_T" AAAA)"
check "DNS: the apex and www are NOT answered with the Pi (R5)" bash -c '[ "$1" != "$3" ] && [ "$2" != "$3" ]' _ "$(dq "$DOMAIN_T" A)" "$(dq "www.$DOMAIN_T" A)" "$LAN_T"
check "DNS: an unlisted lab name is not answered with the Pi" test "$(dq "nothing-here.$DOMAIN_T" A)" != "$LAN_T"
up="$(px pihole-FTL --config dns.upstreams 2> /dev/null | tr -d '[]" \n' || true)"
check "FTL uses the Quad9 upstreams [$up]" test "$up" = "9.9.9.9,149.112.112.112"
check "FTL has DNSSEC on and DHCP off" test "$(px pihole-FTL --config dns.dnssec 2> /dev/null)$(px pihole-FTL --config dhcp.active 2> /dev/null)" = "truefalse"
auth() { px curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data "{\"password\":\"$1\"}" http://127.0.0.1/api/auth 2> /dev/null || true; }
check "the web API accepts the password from the secret file" test "$(auth "$PW_T")" = 200
check "the web API refuses a wrong password" test "$(auth wrong-password)" = 401

echo "--- through Traefik (real flags, routers and middlewares; stub outpost)"
hostport="$(docker port "$cid" 443/tcp | head -n 1 | sed 's/.*://')"
via() { # via <host> <path> [curl args]: prints "<code> <Location header>"; no redirects followed
  local h="$1" p="$2"
  shift 2
  curl -sk -o /dev/null -D - -w 'CODE %{http_code}
' --connect-to "$h:443:127.0.0.1:${hostport}" "$@" "https://$h$p" 2> /dev/null |
    tr -d '\r' | awk '/^CODE /{c=$2} tolower($1)=="location:"{l=$2} END{print (c == "" ? "000" : c), l}' || true
}
viab() {
  local h="$1" p="$2"
  shift 2
  curl -sk --connect-to "$h:443:127.0.0.1:${hostport}" "$@" "https://$h$p" || true
}
ready=0
for _ in $(seq 1 30); do
  case "$(via "pihole.$DOMAIN_T" /admin/)" in 302*) ready=1 && break ;; esac
  sleep 2
done
check "Traefik discovered the Pi-hole routers (anonymous request answered with 302)" test "$ready" = 1
r="$(via "pihole.$DOMAIN_T" /admin/)"
check "anonymous request: 302 to the Authentik authorize endpoint (Pi-hole not reached) [$r]" bash -c '[[ "$1" == "302 https://auth.lab.example.test/application/o/authorize/"* ]]' _ "$r"
r="$(via "pihole.$DOMAIN_T" /api/auth -X POST --data '{"password":"x"}')"
check "anonymous API request is also stopped by forward auth (302, never Pi-hole's 401) [$r]" bash -c '[[ "$1" == 302* ]]' _ "$r"
check "a forged identity header does not bypass forward auth (still 302)" bash -c '[[ "$1" == 302* ]]' _ "$(via "pihole.$DOMAIN_T" /admin/ -H 'X-authentik-username: akadmin')"
check "with an accepted session the Pi-hole web UI answers through Traefik (its own login page)" bash -c 'grep -qi "pi-hole" <<< "$1"' _ "$(viab "pihole.$DOMAIN_T" /admin/login -H 'Cookie: stub_session=ok')"
h="$(curl -skI --connect-to "pihole.$DOMAIN_T:443:127.0.0.1:${hostport}" -H 'Cookie: stub_session=ok' "https://pihole.$DOMAIN_T/admin/login" | tr -d '\r')"
check "the shared security headers are on the Pi-hole response (HSTS, nosniff, frame deny)" bash -c 'grep -qi "^strict-transport-security: max-age=" <<< "$1" && grep -qi "^x-content-type-options: nosniff" <<< "$1" && grep -qi "^x-frame-options: deny" <<< "$1"' _ "$h"
for _ in $(seq 1 20); do
  [ "$(viab "pihole.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB ] && break
  sleep 2
done
check "outpost callback path on the Pi-hole host goes to the outpost" test "$(viab "pihole.$DOMAIN_T" /outpost.goauthentik.io/callback)" = OUTPOST-STUB
docker stop phtest-auth > /dev/null
c="$(via "pihole.$DOMAIN_T" /admin/ -H 'Cookie: stub_session=ok' | cut -d' ' -f1)"
check "Authentik down: the Pi-hole UI is NOT served (forward auth fails closed: got $c)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$c"
check "DNS keeps working while Authentik is down (only the web UI depends on it)" test "$(dq "auth.$DOMAIN_T" A)" = "$LAN_T"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Pi-hole checks passed\n'
