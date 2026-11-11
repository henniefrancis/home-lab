#!/usr/bin/env bash
# test-authentik-config.sh - self-test of the Authentik stack definition (milestone M4). Needs docker (Compose v2.24+) and jq.
#
# Usage: scripts/test-authentik-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (fast, no containers; this is what CI runs)
#   (default)  also boots a throw-away copy of the stack and drives the whole chain (about 5-10 minutes, mostly the first
#              Authentik database migration; amd64 on a laptop or runner, no Pi needed).
#
# Dummy values only: a fake domain (lab.example.test), random secrets generated per run, a self-signed wildcard certificate.
# Nothing is sent to ACME, AWS or any real host. Everything it creates is named aktest-* and removed on exit.
#
# Static checks (plan 6.4): pinned images, no Redis, no published ports, no docker.sock, worker not root and not internal-exposed,
#   file-based secrets, only the proxy network trusted, no cookie domain, memory limits, hardening, uids consistent between
#   lab.env, secrets-manifest.tsv and bootstrap.sh (F02), blueprint content, Traefik labels and middleware.
# Full run: Authentik server + worker + PostgreSQL boot as the non-default uid with a read-only root file system; the blueprint
#   applies; MFA is enforced; the embedded outpost answers forward auth; the REAL Traefik flags, dashboard labels and
#   middlewares redirect an unauthenticated request to the login flow; SSO + MFA enrolment opens the dashboard; cookies are
#   host-only and per app; forged identity headers are replaced; a user outside homelab-admins is denied; fail-closed when
#   Authentik is down; the break-glass router still works then; the recovery command works under the non-default uid.
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
unset PROXY_SUBNET AUTHENTIK_AUTH_SUBNET APPS_ROOT DOMAIN AUTHENTIK_UID AUTHENTIK_GID AUTHENTIK_PG_UID AUTHENTIK_PG_GID TRAEFIK_UID TRAEFIK_GID ITTOOLS_UID ITTOOLS_GID PIHOLE_UID PIHOLE_GID PIHOLE_UPSTREAMS PI_LAN_IP

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
PROJECT=aktest
NET_PROXY=aktest-proxy
NET_INT=aktest-internal
NET_AUTH=aktest-auth
TEST_SUBNET=172.29.88.0/24
TEST_AUTH_SUBNET=172.29.89.0/24
AK_IMAGE=""
PG_IMAGE=""
stage=""
cleanup() {
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f aktest-traefik aktest-whoami > /dev/null 2>&1 || true
    docker compose -p "$PROJECT" --env-file config/lab.env -f authentik/compose.yaml -f "${stage:-/nonexistent}/override.yaml" down -v --remove-orphans > /dev/null 2>&1 || true
    docker volume rm "${PROJECT}_aktest-data" "${PROJECT}_aktest-pg" > /dev/null 2>&1 || true
    docker network rm "$NET_PROXY" "$NET_INT" "$NET_AUTH" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT

# --------------------------------------------------------------------------------------------------------------------
# Static review. The root project is rendered (traefik + authentik + tailscale), as deploy.sh does.
# --------------------------------------------------------------------------------------------------------------------
stage="$(mktemp -d -p . .authentik-test.XXXXXX)"
apps_host="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })" # a path docker.exe understands under Git Bash, plain pwd elsewhere
AK_SECRET="$(openssl rand -hex 32)"
PG_SECRET="$(openssl rand -hex 16)"
ADMIN_PW="$(openssl rand -hex 12)"
OUTSIDER_PW="$(openssl rand -hex 12)"
OUTSIDER_TOTP_HEX="$(openssl rand -hex 20)"
BG_PW="$(openssl rand -hex 8)"
mkdir -p "$stage/secrets/authentik" "$stage/secrets/tailscale" "$stage/secrets/traefik"
: > "$stage/secrets/tailscale/tailscale.env"
printf '%s' "$AK_SECRET" > "$stage/secrets/authentik/secret-key"
printf '%s' "$PG_SECRET" > "$stage/secrets/authentik/postgres-password"
printf '%s' "$ADMIN_PW" > "$stage/secrets/authentik/bootstrap-password"
# M9: the Linkwarden OAuth2 client secret, which the worker exports for the blueprint (!Env LINKWARDEN_OIDC_CLIENT_SECRET).
LW_CLIENT_SECRET="$(openssl rand -hex 32 | tr -d '\r\n')"
printf '%s' "$LW_CLIENT_SECRET" > "$stage/secrets/authentik/linkwarden-oidc-client-secret"
printf 'admin:%s\n' "$(openssl passwd -apr1 "$BG_PW")" > "$stage/secrets/traefik/breakglass-htpasswd"
# Ownership as scripts/fetch-secrets.sh would set it, when this runs as root on Linux (CI). Elsewhere (Docker Desktop) the
# bind-mount ownership is not meaningful and the permission-sensitive reads are only proven on a Linux root run.
perms_real=0
if chown 10002:10002 "$stage/secrets/authentik/secret-key" 2> /dev/null && [ "$(stat -c %u "$stage/secrets/authentik/secret-key" 2> /dev/null)" = 10002 ]; then
  chown 10002:10002 "$stage/secrets/authentik/postgres-password" "$stage/secrets/authentik/bootstrap-password"
  chown 10002:10007 "$stage/secrets/authentik/linkwarden-oidc-client-secret"
  chmod 0440 "$stage/secrets/authentik/linkwarden-oidc-client-secret"
  chmod 0400 "$stage/secrets/authentik/secret-key" "$stage/secrets/authentik/bootstrap-password"
  chmod 0440 "$stage/secrets/authentik/postgres-password"
  perms_real=1
fi

export APPS_ROOT="$apps_host" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role PI_LAN_IP=10.0.0.2
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
ak="$(jq -c '.services | with_entries(select(.key | startswith("authentik-")))' <<< "$all")"
AK_IMAGE="$(jq -r '.["authentik-server"].image' <<< "$ak")"
PG_IMAGE="$(jq -r '.["authentik-postgresql"].image' <<< "$ak")"
printf 'images: %s, %s\n' "$AK_IMAGE" "$PG_IMAGE"

echo "--- static: images and services"
check "root compose renders Authentik server, worker and PostgreSQL only (no Redis anywhere)" test "$(jq -c 'keys' <<< "$ak")" = '["authentik-postgresql","authentik-server","authentik-worker"]' -a "$(jq -r '.services | keys[]' <<< "$all" | grep -ci redis)" = 0
check "Authentik image is a pinned 2026.8.x patch release, by digest (not latest, not a bare minor, SEC-M5)" bash -c '[[ "$1" =~ ^ghcr\.io/goauthentik/server:2026\.8\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$AK_IMAGE"
check "PostgreSQL image is a pinned 16.x-alpine release, by digest (SEC-M5)" bash -c '[[ "$1" =~ ^postgres:16\.[0-9]+-alpine[0-9.]*@sha256:[0-9a-f]{64}$ ]]' _ "$PG_IMAGE"
check "server and worker run the same image" test "$(jq -r '.["authentik-server"].image' <<< "$ak")" = "$(jq -r '.["authentik-worker"].image' <<< "$ak")"
check "every Authentik service has a memory limit" test "$(jq '[.[] | select((.mem_limit // 0 | tonumber) > 0)] | length' <<< "$ak")" = 3
check "memory limits: postgres 512M, server 1G, worker 768M" test "$(jq -c '[.["authentik-postgresql"].mem_limit, .["authentik-server"].mem_limit, .["authentik-worker"].mem_limit]' <<< "$ak")" = '["536870912","1073741824","805306368"]'
check "no published ports on any Authentik service (reached through Traefik only)" test "$(jq '[.[] | .ports // [] | length] | add' <<< "$ak")" = 0
check "docker.sock is mounted into no Authentik service (the official worker mounts it)" bash -c '! jq -r ".[] | .volumes[]? | .source" <<< "$1" | grep -q "docker.sock"' _ "$ak"
check "no Authentik service is privileged, root, or keeps capabilities" test "$(jq '[.[] | select((.privileged // false) or (.user // "") == "root" or (.user // "") == "0" or ((.cap_drop // []) | index("ALL") | not) or (.cap_add // [] | length > 0))] | length' <<< "$ak")" = 0
check "server and worker run as AUTHENTIK_UID:AUTHENTIK_GID (10002), not the image default 1000" test "$(jq -c '[.["authentik-server"].user, .["authentik-worker"].user]' <<< "$ak")" = '["10002:10002","10002:10002"]'
check "PostgreSQL runs as 70:70 with the Authentik group added (reads postgres-password via group)" test "$(jq -c '[.["authentik-postgresql"].user, .["authentik-postgresql"].group_add]' <<< "$ak")" = '["70:70",["10002"]]'
check "server and worker: read-only root fs, no-new-privileges" test "$(jq '[.["authentik-server"], .["authentik-worker"] | select(.read_only == true and (.security_opt | index("no-new-privileges:true")))] | length' <<< "$ak")" = 2
check "PostgreSQL: read-only root fs, no-new-privileges, tmpfs only for the socket directory and /tmp (SEC-L9)" test "$(jq -c '[.["authentik-postgresql"] | .read_only, (.security_opt | index("no-new-privileges:true") != null), ([.tmpfs[] | split(":")[0]] | sort)]' <<< "$ak")" = '[true,true,["/tmp","/var/run/postgresql"]]'
check "worker is not on the proxy network and has no Traefik labels (internal only)" test "$(jq -c '[.["authentik-worker"].networks | keys[]]' <<< "$ak")" = '["authentik-internal"]' -a "$(jq '.["authentik-worker"].labels // {} | length' <<< "$ak")" = 0
check "PostgreSQL is on the internal network only" test "$(jq -c '[.["authentik-postgresql"].networks | keys[]]' <<< "$ak")" = '["authentik-internal"]'
check "server is on authentik-auth (shared with Traefik only) and the internal network, NOT on proxy (SEC-L8)" test "$(jq -c '[.["authentik-server"].networks | keys[]] | sort' <<< "$ak")" = '["authentik-auth","authentik-internal"]' 
check "authentik-internal and authentik-auth are declared external (created by bootstrap.sh); no socket-proxy network" test "$(jq -c '[.networks["authentik-internal"].external, .networks["authentik-auth"].external, (.networks | has("socket-proxy"))]' <<< "$all")" = '[true,true,false]' 
check "every Authentik service uses json-file rotation 10m x 3" test "$(jq '[.[] | select(.logging.driver == "json-file" and .logging.options["max-size"] == "10m" and .logging.options["max-file"] == "3")] | length' <<< "$ak")" = 3

echo "--- static: secrets and trust"
check "Authentik secrets come from files (file://), none is a literal in the environment" test "$(jq -c '[.["authentik-server"].environment, .["authentik-worker"].environment | [.AUTHENTIK_SECRET_KEY, .AUTHENTIK_POSTGRESQL__PASSWORD]]' <<< "$ak")" = '[["file:///run/secrets/authentik_secret_key","file:///run/secrets/pg_password"],["file:///run/secrets/authentik_secret_key","file:///run/secrets/pg_password"]]'
check "PostgreSQL uses POSTGRES_PASSWORD_FILE and has no POSTGRES_PASSWORD" test "$(jq -r '.["authentik-postgresql"].environment | [.POSTGRES_PASSWORD_FILE, (.POSTGRES_PASSWORD // "none")] | join(" ")' <<< "$ak")" = "/run/secrets/pg_password none"
check "no secret-looking literal appears in the rendered environment of any service" bash -c '! jq -r ".[] | .environment // {} | to_entries[] | .value" <<< "$1" | grep -v "^file://" | grep -Eq "^(.{40,}|[0-9a-f]{32,})$"' _ "$ak"
check "bootstrap password is exported by an entrypoint wrapper from its secret file, worker only (!Env cannot read file://)" bash -c 'jq -e ".[\"authentik-worker\"].entrypoint | join(\" \") | test(\"(?s)authentik_bootstrap_password.*AUTHENTIK_BOOTSTRAP_PASSWORD\")" <<< "$1" && ! jq -e ".[\"authentik-server\"].environment | has(\"AUTHENTIK_BOOTSTRAP_PASSWORD\")" <<< "$1"' _ "$ak"
check "trusted proxy CIDRs are the authentik-auth subnet only (AUTHENTIK_AUTH_SUBNET), not Authentik's 10/8 172.16/12 192.168/16 default" test "$(jq -r '.["authentik-server"].environment.AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS' <<< "$ak")" = "$(grep -E '^AUTHENTIK_AUTH_SUBNET=' config/lab.env | cut -d= -f2)" 
check "no AUTHENTIK_COOKIE_DOMAIN anywhere (host-only cookies)" bash -c '! grep -rIn "COOKIE_DOMAIN\|cookie_domain" authentik/ traefik/ config/ | grep -v "^authentik/compose.yaml:.*#\|^authentik/blueprints/homelab-apps.yaml:.*#"' _
check "error reporting, update check and analytics are off" test "$(jq -c '.["authentik-server"].environment | [.AUTHENTIK_ERROR_REPORTING__ENABLED, .AUTHENTIK_DISABLE_UPDATE_CHECK, .AUTHENTIK_DISABLE_STARTUP_ANALYTICS]' <<< "$ak")" = '["false","true","true"]'
check "the worker's task time limit is 60 minutes (a blueprint apply on the Pi takes longer than the 10-minute default)" test "$(jq -r '.["authentik-worker"].environment.AUTHENTIK_WORKER__TASK_DEFAULT_TIME_LIMIT' <<< "$ak" | tr -d '')" = "minutes=60"
check "authentik-server carries no Traefik labels; its router is a file (auth.<domain>, oidc-allowlist only: the LAN, the tailnet and the OIDC back-channel, M9; service on :9000)" bash -c 'test "$(jq ".[\"authentik-server\"].labels // {} | length" <<< "$1")" = 0 && f=traefik/dynamic/routers.yml && grep -q "service: authentik" $f && grep -q "url: http://authentik-server:9000" $f && m="$(awk "/^  services:/{exit} /^    authentik:/{f=1;next} /^    [a-z-]+:\$/{f=0;g=0} f&&/middlewares:/{g=1;next} f&&g&&/^ +- /{print}" $f)" && [ "$(wc -l <<< "$m")" = 1 ] && grep -qE "^ +- oidc-allowlist$" <<< "$m"' _ "$ak"
check "no other container can reach authentik-server: only the proxy-less authentik-auth network carries it" test "$(jq -c '[.services | to_entries[] | select(.value.networks | has("authentik-auth")) | .key] | sort' <<< "$all")" = '["authentik-server","traefik"]' 

echo "--- static: service ids (F02)"
lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2; }
manifest_owner() { awk -F'\t' -v p="$1" '$1 == p {print $3 " " $4}' config/secrets-manifest.tsv; }
check "lab.env service ids are 10002 (Authentik), 70 (PostgreSQL), 10003 (Homepage), 10004 (Traefik); none is 1000" test "$(lab_get AUTHENTIK_UID) $(lab_get AUTHENTIK_GID) $(lab_get AUTHENTIK_PG_UID) $(lab_get AUTHENTIK_PG_GID) $(lab_get HOMEPAGE_UID) $(lab_get TRAEFIK_UID)" = "10002 10002 70 70 10003 10004" 
check "manifest: secret-key 10002:10002 0400" test "$(manifest_owner authentik/secret-key)" = "10002:10002 0400"
check "manifest: postgres-password 10002:10002 0440 (group read for uid 70)" test "$(manifest_owner authentik/postgres-password)" = "10002:10002 0440"
check "manifest: bootstrap-password 10002:10002 0400, empty file while UNSET" test "$(manifest_owner authentik/bootstrap-password)" = "10002:10002 0400" -a "$(awk -F'\t' '$1 == "authentik/bootstrap-password" {print $5}' config/secrets-manifest.tsv)" = empty
check "manifest: no row is owned by uid or gid 1000 (the login user)" bash -c '! awk -F"\t" "\$1 !~ /^#/ && \$3 ~ /(^|:)1000\$|^1000:/" config/secrets-manifest.tsv | grep -q .'
check "bootstrap.sh creates the data dirs with those ids from lab.env and refuses 0 and 1000" bash -c 'grep -q "AUTHENTIK_UID" scripts/bootstrap.sh && grep -q "AUTHENTIK_PG_UID" scripts/bootstrap.sh && grep -q "authentik/data" scripts/bootstrap.sh && grep -q "authentik/postgres" scripts/bootstrap.sh && grep -q -- "-ne 1000" scripts/bootstrap.sh'
check "preflight.sh checks that the service ids are not host users" grep -q 'svc-id:' scripts/preflight.sh

echo "--- static: blueprint, Traefik labels and middleware"
bp=authentik/blueprints/homelab-apps.yaml
check "blueprint: six forward_single proxy providers (Traefik, dashboard, IT Tools, Pi-hole, Netdata, Portainer), no cookie domain" bash -c 'f=$1; [ "$(grep -v "^\s*#" $f | grep -c "mode: forward_single")" = 6 ] && ! grep -v "^\s*#" $f | grep -q cookie_domain' _ $bp
check "blueprint: external hosts use the DOMAIN env var, no literal domain" bash -c '[ "$(grep -c "!Env DOMAIN" "$1")" -ge 5 ] && ! grep -v "^\s*#" "$1" | grep -Eq "https://[a-z]+\.[a-z0-9-]+\.[a-z]{2,}"' _ $bp
check "blueprint: MFA enforced (configure, totp + webauthn)" bash -c 'grep -q "not_configured_action: configure" "$1" && grep -q "^        - totp" "$1" && grep -q "^        - webauthn" "$1"' _ $bp
check "blueprint: group homelab-admins bound to all seven applications (fail-closed); homelab-users only to Linkwarden" test "$(grep -c 'group: !KeyOf group-admins' $bp)" = 7 -a "$(grep -c 'group: !KeyOf group-users' $bp)" = 1 -a "$(grep -c 'name: homelab-admins' $bp)" = 1
check "blueprint: group membership is seeded once (state: created), never overwritten" bash -c 'awk "/id: group-admins/{f=1} f&&/state: created/{print; exit}" "$1" | grep -q created' _ $bp
check "blueprint: embedded outpost carries the six forward-auth providers (not the OAuth2 one)" bash -c 'grep -q "managed: goauthentik.io/outposts/embedded" "$1" && [ "$(awk "/managed: goauthentik.io\/outposts\/embedded/{f=1} f&&/- !KeyOf provider-/" "$1" | wc -l)" = 6 ] && ! awk "/managed: goauthentik.io\/outposts\/embedded/{f=1} f" "$1" | grep -q provider-linkwarden' _ $bp
check "blueprint is mounted read-only into server and worker" test "$(jq -c '[.["authentik-server"].volumes[], .["authentik-worker"].volumes[] | select(.target == "/blueprints/custom") | .read_only]' <<< "$ak")" = '[true,true]'

tjson="$(docker compose -f traefik/compose.yaml --env-file config/lab.env config --format json)"
rt=traefik/dynamic/routers.yml
check "routers.yml: dashboard router = lan-allowlist then authentik, service api@internal, no basic auth" bash -c 'awk "/^    dashboard:/{f=1;next} /^    [a-z-]+:/{f=0} f" "$1" | tr -d " " | tr "\n" "|" | grep -q "service:api@internal|middlewares:|-lan-allowlist|-authentik|"' _ $rt
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
check "routers.yml: each *-outpost router = app host + /outpost.goauthentik.io/ -> service authentik, priority 100, allowlist only (no forward auth: it would loop)" bash -c 'for r in dashboard-outpost homepage-outpost it-tools-outpost pihole-outpost netdata-outpost portainer-outpost; do b="$(router_block $r)"; grep -q "PathPrefix" <<< "$b" && grep -q "/outpost.goauthentik.io/" <<< "$b" && grep -q "priority: 100" <<< "$b" && grep -q "service: authentik$" <<< "$b" && grep -q -- "- lan-allowlist$" <<< "$b" && ! grep -q -- "- authentik$" <<< "$b" || exit 1; done' _
check "break-glass is not a router of the default config (only the drop-in provides it)" bash -c '! grep -q "bg-traefik" traefik/dynamic/*.yml && grep -q "breakglass-auth" traefik/breakglass/bg-traefik.yml && grep -q "lan-allowlist" traefik/breakglass/bg-traefik.yml'
check "middleware authentik: embedded outpost address on the authentik-auth network, trustForwardHeader, the 12 documented headers" bash -c 'f=traefik/dynamic/middlewares.yml; grep -q "address: http://authentik-server:9000/outpost.goauthentik.io/auth/traefik" $f && grep -q "trustForwardHeader: true" $f && [ "$(grep -c "^          - X-authentik-" $f)" = 12 ]'
check "lan-allowlist ranges unchanged (LAN + tailnet)" bash -c 'f=traefik/dynamic/middlewares.yml; grep -q "10.0.0.0/24" $f && grep -q "100.64.0.0/10" $f'

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Authentik checks passed (run without --static for the boot and forward-auth test)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
# Full run: boot a copy of the real definition on private networks and named volumes.
# --------------------------------------------------------------------------------------------------------------------
echo "--- boot: Authentik server + worker + PostgreSQL (first start migrates the database: several minutes)"
cat > "$stage/override.yaml" << EOF
---
# Test only: private network names/subnet and named volumes (a Windows bind mount cannot hold a 0700 Postgres directory).
services:
  authentik-postgresql:
    volumes: !override
      - aktest-pg:/var/lib/postgresql/data
  authentik-server:
    volumes: !override
      - aktest-data:/data
      - ./blueprints:/blueprints/custom:ro
  authentik-worker:
    volumes: !override
      - aktest-data:/data
      - ./blueprints:/blueprints/custom:ro
networks:
  proxy:
    name: $NET_PROXY
    external: !reset null
    ipam:
      config:
        - subnet: $TEST_SUBNET
  authentik-auth:
    name: $NET_AUTH
    external: !reset null
    ipam:
      config:
        - subnet: $TEST_AUTH_SUBNET
  authentik-internal:
    name: $NET_INT
    external: !reset null
    internal: true
volumes:
  aktest-pg:
  aktest-data:
EOF
export PROXY_SUBNET="$TEST_SUBNET" AUTHENTIK_AUTH_SUBNET="$TEST_AUTH_SUBNET"
dc() { docker compose -p "$PROJECT" --env-file config/lab.env -f authentik/compose.yaml -f "$stage/override.yaml" "$@"; }
dc create > /dev/null 2>&1 || {
  bad "compose create failed"
  dc create 2>&1 | tail -5
  exit 1
}
# bootstrap.sh gives these directories to the service ids; the named volumes need the same.
docker run --rm -v "${PROJECT}_aktest-data:/d" alpine sh -c 'chown 10002:10002 /d && chmod 700 /d'
docker run --rm -v "${PROJECT}_aktest-pg:/d" alpine sh -c 'chown 70:70 /d && chmod 700 /d'
dc up -d > /dev/null 2>&1

wait_healthy() { # wait_healthy <seconds>
  local end=$((SECONDS + $1)) st
  while [ "$SECONDS" -lt "$end" ]; do
    st="$(dc ps --format '{{.Name}}={{.Health}}' | sort | tr '\n' ' ')"
    case "$st" in *"authentik-postgresql=healthy"*"authentik-server=healthy"*"authentik-worker=healthy"*) return 0 ;; esac
    sleep 10
  done
  return 1
}
if wait_healthy 1200; then ok "postgres, server and worker are healthy (non-default uid, read-only root, file secrets)"; else
  bad "stack did not become healthy"
  dc ps
  dc logs --tail 30
  exit 1
fi
check "server runs as 10002 and worker as 10002" test "$(dc exec -T authentik-server id -u)-$(dc exec -T authentik-worker id -u)" = "10002-10002"
check "PostgreSQL runs as uid 70" test "$(dc exec -T authentik-postgresql id -u)" = "70"
if [ "$perms_real" -eq 1 ]; then ok "secret files had their real owners (10002:10002, 0400/0440) and every service could read its own"; else echo "SKIP  real owner/mode of secret files (needs a Linux root run, as in CI; not meaningful on Docker Desktop)"; fi
check "root file system is read-only in server and worker" bash -c '! docker exec "$1" sh -c "touch /usr/x" 2> /dev/null && ! docker exec "$2" sh -c "touch /usr/x" 2> /dev/null' _ authentik-server authentik-worker
check "worker has no docker.sock and no ability to reach one" bash -c '! docker exec "$1" sh -c "test -S /var/run/docker.sock"' _ authentik-worker
no_egress() { ! docker exec authentik-worker python -c 'import socket; socket.create_connection(("1.1.1.1", 443), 3)' 2> /dev/null; }
check "worker has no route to the outside (internal network, no egress)" no_egress
check "Authentik does not listen on the host (no published ports)" test -z "$(docker port authentik-server)"

# One Python helper per call runs in the worker through `ak shell` (blueprint state, users, recovery key).
akshell() { dc exec -T -e OUTSIDER_PW="$OUTSIDER_PW" -e OUTSIDER_TOTP_HEX="$OUTSIDER_TOTP_HEX" authentik-worker ak shell 2> /dev/null; }
echo "--- blueprint"
bp_ok=0
for _ in $(seq 1 30); do
  st="$(printf 'from authentik.blueprints.models import BlueprintInstance as B\nprint("BPSTATE", B.objects.filter(name__startswith="Home lab").values_list("status", flat=True).first())\n' | akshell | sed -n 's/^BPSTATE //p')"
  [ "$st" = successful ] && {
    bp_ok=1
    break
  }
  sleep 10
done
check "the blueprint 'Home lab - SSO apps, MFA and embedded outpost' applied successfully" test "$bp_ok" = 1
state="$(printf '%s\n' \
  'from authentik.core.models import User' \
  'from authentik.providers.proxy.models import ProxyProvider as P' \
  'from authentik.outposts.models import Outpost as O' \
  'from authentik.providers.oauth2.models import OAuth2Provider as O2' \
  'from authentik.core.models import Application as A, Group as G' \
  'from authentik.stages.authenticator_validate.models import AuthenticatorValidateStage as S' \
  'u = User.objects.get(username="akadmin")' \
  'print("STATE pw", u.check_password(open("/run/secrets/authentik_bootstrap_password").read().strip()))' \
  'print("STATE groups", sorted(g.name for g in u.ak_groups.all()))' \
  'print("STATE providers", sorted((p.name, p.mode, p.external_host, p.cookie_domain) for p in P.objects.all()))' \
  'print("STATE outpost", [(o.managed, sorted(p.name for p in o.providers.all()), o.config.authentik_host) for o in O.objects.all()])' \
  'o2 = O2.objects.get(name="homelab-linkwarden")' \
  'print("STATE oauth2", o2.client_id, o2.client_type, [(r.url, str(getattr(r.matching_mode, "value", r.matching_mode))) for r in o2.redirect_uris], o2.client_secret == open("/run/secrets/linkwarden_oidc_client_secret").read().strip(), sorted(o2.grant_types))' \
  'print("STATE lwgroups", sorted(b.group.name for b in A.objects.get(slug="linkwarden").bindings.all()))' \
  'print("STATE usersgroup", G.objects.filter(name="homelab-users").count(), G.objects.get(name="homelab-users").users.count())' \
  's = S.objects.get(name="default-authentication-mfa-validation")' \
  'print("STATE mfa", s.not_configured_action, s.device_classes)' | akshell | sed -n 's/^STATE //p')"
check "akadmin exists and the bootstrap secret file is her password (wrapper exported it for the blueprint)" grep -q '^pw True' <<< "$state"
check "akadmin is a member of homelab-admins (seeded by the blueprint)" grep -q "^groups \[.*'homelab-admins'" <<< "$state"
check "all six forward-auth providers with the right external host and an EMPTY cookie domain" grep -q "^providers \[('homelab-dashboard', 'forward_single', 'https://dashboard.${DOMAIN_T}', ''), ('homelab-it-tools', 'forward_single', 'https://tools.${DOMAIN_T}', ''), ('homelab-netdata', 'forward_single', 'https://netdata.${DOMAIN_T}', ''), ('homelab-pihole', 'forward_single', 'https://pihole.${DOMAIN_T}', ''), ('homelab-portainer', 'forward_single', 'https://portainer.${DOMAIN_T}', ''), ('homelab-traefik', 'forward_single', 'https://traefik.${DOMAIN_T}', '')\]" <<< "$state"
check "the embedded outpost carries the six forward-auth providers and points at https://auth.<domain>" grep -q "^outpost \[('goauthentik.io/outposts/embedded', \['homelab-dashboard', 'homelab-it-tools', 'homelab-netdata', 'homelab-pihole', 'homelab-portainer', 'homelab-traefik'\], 'https://auth.${DOMAIN_T}')\]" <<< "$state"
check "MFA validation stage: configure, totp + webauthn" grep -q "^mfa configure \['totp', 'webauthn'\]" <<< "$state"
check "M9: the Linkwarden OAuth2 provider is confidential, client id linkwarden, one strict redirect, its secret is the SSM file (exported by the worker), grant types code and refresh only [$(grep '^oauth2 ' <<< "$state")]" grep -q "^oauth2 linkwarden confidential \[('https://links.${DOMAIN_T}/api/v1/auth/callback/authentik', 'strict')\] True \['authorization_code', 'refresh_token'\]$" <<< "$state"
check "M9: Linkwarden is bound to homelab-admins and homelab-users; homelab-users exists and the blueprint gave it no members" bash -c 'grep -q "^lwgroups \[.homelab-admins., .homelab-users.\]" <<< "$1" && grep -q "^usersgroup 1 0" <<< "$1"' _ "$state"

echo "--- recovery path"
rk="$(dc exec -T authentik-server ak create_recovery_key 2 akadmin 2>&1 | grep -c '^/recovery/use-token/' || true)"
check "ak create_recovery_key works under uid 10002 without a passwd entry (USER=authentik set)" test "$rk" = 1

# --------------------------------------------------------------------------------------------------------------------
# Traefik: the REAL static flags, the REAL dynamic files (routers.yml with its DOMAIN template, middlewares.yml with the allowlist
# widened so the test client passes), a dummy certificate, and the break-glass drop-in switched on and off like breakglass.sh does.
# --------------------------------------------------------------------------------------------------------------------
echo "--- Traefik forward auth"
timage="$(jq -r '.services.traefik.image' <<< "$tjson")"
mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$tjson" | tr -d '\r')

mkdir -p "$stage/tr/dynamic"
cp traefik/dynamic/*.yml "$stage/tr/dynamic/"
sed -i 's#- 10.0.0.0/24#- 0.0.0.0/0#' "$stage/tr/dynamic/middlewares.yml" # the test client is a Docker gateway address
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$stage/tr/dynamic/test-k.pem" \
  -out "$stage/tr/dynamic/test-c.pem" -days 2 -subj "/CN=*.${DOMAIN_T}" -addext "subjectAltName=DNS:*.${DOMAIN_T}" 2> /dev/null
cat > "$stage/tr/dynamic/test-cert.yml" << 'EOF'
tls:
  certificates:
    - certFile: /etc/traefik/dynamic/test-c.pem
      keyFile: /etc/traefik/dynamic/test-k.pem
EOF
# Authentik no longer uses the proxy network (server is on authentik-auth), so compose does not create it: make it for the test.
docker network inspect "$NET_PROXY" > /dev/null 2>&1 || docker network create --subnet "$TEST_SUBNET" "$NET_PROXY" > /dev/null
# Stand-in backend for the real "homepage" router (http://homepage:3000): whoami listening on 3000 under the network alias homepage.
docker run -d --name aktest-whoami --network "$NET_PROXY" --network-alias homepage traefik/whoami:v1.12.0 --port 3000 > /dev/null
cid="$(docker create --name aktest-traefik --network "$NET_PROXY" -p 127.0.0.1::443 \
  -e DOMAIN="$DOMAIN_T" -e AWS_REGION=us-east-1 -e AWS_HOSTED_ZONE_ID="$ROUTE53_ZONE_ID" -e AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911 \
  -v "$apps_host/secrets/traefik/breakglass-htpasswd:/run/secrets/breakglass_users:ro" --tmpfs /letsencrypt "$timage" "${flags[@]}")"
docker network connect "$NET_AUTH" "$cid"
chmod 644 "$stage/tr/dynamic/test-k.pem"
docker cp "$stage/tr/." "$cid:/etc/traefik"
docker start "$cid" > /dev/null
sleep 6
check "traefik is running with the real flags" test "$(docker inspect -f '{{.State.Running}}' "$cid")" = true
tip="$(docker inspect "$cid" -f "{{(index .NetworkSettings.Networks \"$NET_PROXY\").IPAddress}}")"
hostport="$(docker port "$cid" 443/tcp | head -n 1 | sed 's/.*://')"
# The outpost starts a little after the blueprint adds the providers; wait for forward auth to answer 302 (not 404).
ready=0
for _ in $(seq 1 36); do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-to "traefik.${DOMAIN_T}:443:127.0.0.1:${hostport}" "https://traefik.${DOMAIN_T}/" || true)"
  [ "$code" = 302 ] && {
    ready=1
    break
  }
  sleep 5
done
check "unauthenticated request to the dashboard host gets 302 (embedded outpost answers forward auth)" test "$ready" = 1
check "Traefik reports no error for the authentik middleware or the outpost routers" bash -c '! docker logs "$1" 2>&1 | jq -R -r "fromjson? | select(.level==\"error\") | .msg" | grep -Ei "authentik|outpost|forwardauth|middleware|dashboard"' _ "$cid"

# A user outside homelab-admins, with password + TOTP, to prove the fail-closed binding.
printf '%s\n' \
  'import os' \
  'from authentik.core.models import User' \
  'from authentik.stages.authenticator_totp.models import TOTPDevice' \
  'u, _ = User.objects.get_or_create(username="outsider", defaults={"name": "Outsider", "email": "outsider@example.test"})' \
  'u.set_password(os.environ["OUTSIDER_PW"]); u.save()' \
  'TOTPDevice.objects.update_or_create(user=u, name="test", defaults={"confirmed": True, "key": os.environ["OUTSIDER_TOTP_HEX"]})' \
  'print("MKUSER ok")' | akshell | grep -q 'MKUSER ok' || bad "could not create the outsider test user"

echo "--- end to end (driver: scripts/testdata/authentik-e2e.py, runs in the Authentik image on the test network)"
rc=0
docker run --rm -i --network "$NET_PROXY" \
  --add-host "auth.${DOMAIN_T}:${tip}" --add-host "traefik.${DOMAIN_T}:${tip}" --add-host "dashboard.${DOMAIN_T}:${tip}" \
  -e DOMAIN="$DOMAIN_T" -e ADMIN_PW="$ADMIN_PW" -e OUTSIDER_PW="$OUTSIDER_PW" -e OUTSIDER_TOTP_HEX="$OUTSIDER_TOTP_HEX" \
  --entrypoint /ak-root/.venv/bin/python "$AK_IMAGE" - < scripts/testdata/authentik-e2e.py | tee "$stage/e2e.log" || rc=$?
fails=$((fails + $(grep -c '^FAIL' "$stage/e2e.log" || true)))
[ "$rc" -eq 0 ] || [ "$(grep -c '^FAIL' "$stage/e2e.log" || true)" -gt 0 ] || bad "e2e driver crashed (exit $rc)"

echo "--- fail closed, break-glass, and no loop"
probe() { curl -sk -o /dev/null -w '%{http_code}' --connect-to "$1.${DOMAIN_T}:443:127.0.0.1:${hostport}" "${@:2}" "https://$1.${DOMAIN_T}/" || true; }
docker stop authentik-server > /dev/null
code="$(probe traefik)"
check "Authentik down: the dashboard is NOT served (forward auth fails closed: got $code)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$code"
code="$(probe dashboard)"
check "Authentik down: the app behind forward auth is NOT served either (got $code)" bash -c '[ "$1" != 200 ] && [ "$1" -ge 400 ]' _ "$code"
code="$(probe bg-traefik)"
check "break-glass is OFF until the drop-in exists: bg-traefik.<domain> has no router (404)" test "$code" = 404
docker cp traefik/breakglass/bg-traefik.yml "$cid:/etc/traefik/dynamic/bg-traefik.yml"
docker exec -u 0 "$cid" chmod 0644 /etc/traefik/dynamic/bg-traefik.yml
sleep 5
code="$(probe bg-traefik)"
check "break-glass without credentials: 401 (basic auth, not Authentik)" test "$code" = 401
code="$(probe bg-traefik -u "admin:${BG_PW}")"
check "break-glass with the htpasswd credentials reaches the dashboard while Authentik is down (got $code)" bash -c '[ "$1" = 200 ] || [ "$1" = 301 ] || [ "$1" = 302 ]' _ "$code"
docker exec -u 0 "$cid" rm -f /etc/traefik/dynamic/bg-traefik.yml
sleep 5
code="$(probe bg-traefik -u "admin:${BG_PW}")"
check "break-glass OFF again: the router is gone even with the right credentials (404, SEC-L3)" test "$code" = 404
docker start authentik-server > /dev/null
recovered=0
for _ in $(seq 1 24); do
  [ "$(probe traefik)" = 302 ] && {
    recovered=1
    break
  }
  sleep 5
done
check "Authentik back up: forward auth answers again" test "$recovered" = 1

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Authentik checks passed\n'
