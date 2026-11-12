#!/usr/bin/env bash
# test-linkwarden-config.sh - self-test of the Linkwarden stack (R17, milestone M9). Needs docker (Compose v2.24+), jq, curl, openssl.
#
# Usage: scripts/test-linkwarden-config.sh [--static]
#   --static   only the checks on the rendered definition and the committed files (no containers)
#   (default)  also boots the real images (Linkwarden is about 2.5 GB) and the real Traefik routers (CI runs this)
#
# Dummy values only: a fake domain (lab.example.test), throw-away secrets, a self-signed wildcard certificate and a stub in place of
# authentik-server (the NGINX image already pinned in it-tools/Dockerfile). Nothing is sent to AWS or any real host. Everything it
# creates is named lwtest-* and removed on exit. Named volumes (not bind mounts) hold the data: the containers make their files owned
# by 10007 and 70, which the runner user could not delete, and volume-nocopy stops Docker from copying the image's root-owned
# directories over the ownership the test sets.
#
# Static: pinned images; uids (Linkwarden and Meilisearch 10007, PostgreSQL 70; never root or 1000); read-only roots, cap_drop ALL,
#   no-new-privileges, limits; secrets only as files with the wrappers that export them; OIDC-only login (credentials and
#   registration off, Authentik on with the right issuer, client id and NEXTAUTH_URL); networks (Linkwarden on proxy, oidc and the
#   internal network; the database and search on the internal one only); the router, the OIDC back-channel (Traefik alias, the
#   Authentik router's oidc-allowlist with OIDC_SUBNET), the Authentik OAuth2 provider and the household group, manifest rows,
#   bootstrap and preflight, the tile, Dependabot.
# Full run: the three containers start with the rendered definition and become healthy; every process is uid 10007 with no capability
#   and no_new_privs; the root is read-only; the database came up through the password file; only the Authentik login is offered; the
#   command equals the image's CMD; through the REAL Traefik routers links.<domain> is served with the security headers; from the oidc
#   network auth.<domain> reaches the Authentik service (the allowlist lets the back-channel through), and from the proxy network it
#   is refused (403).
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
NET_PROXY=lwtest-proxy
NET_OIDC=lwtest-oidc
NET_INT=lwtest-internal
VOLS=(lwtest-data lwtest-meili lwtest-pg)
stage=""
cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  if [ "$STATIC_ONLY" -eq 0 ]; then
    docker rm -f lwtest-app lwtest-meili lwtest-pg lwtest-traefik lwtest-auth lwtest-probe > /dev/null 2>&1 || true
    docker network rm "$NET_PROXY" "$NET_OIDC" "$NET_INT" > /dev/null 2>&1 || true
    docker volume rm "${VOLS[@]}" > /dev/null 2>&1 || true
  fi
  [ -z "$stage" ] || rm -rf "$stage"
}
trap cleanup EXIT
trap "exit 130" INT TERM # so a stopped run still removes its containers, networks and volumes

stage="$(mktemp -d -p "${LINKWARDEN_TEST_TMP:-.}" .linkwarden-test.XXXXXX)"
here="$(cd "$stage" && { pwd -W 2> /dev/null || pwd; })"
mkdir -p "$stage/secrets/tailscale" "$stage/secrets/authentik" "$stage/secrets/traefik" "$stage/secrets/pihole" "$stage/secrets/linkwarden"
: > "$stage/secrets/tailscale/tailscale.env"
for s in linkwarden/postgres-password linkwarden/nextauth-secret linkwarden/meili-key authentik/linkwarden-oidc-client-secret; do
  # \r too: openssl on Git Bash ends its line with CRLF, and a carriage return inside the Meilisearch key breaks the HTTP header.
  openssl rand -hex 32 | tr -d '\r\n' > "$stage/secrets/$s"
  chmod 644 "$stage/secrets/$s"
done

export APPS_ROOT="$here" DOMAIN="$DOMAIN_T" ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor RA_ACME_PROFILE_ARN=dummy-profile RA_ACME_ROLE_ARN=dummy-role
export ACME_CA_SERVER=https://127.0.0.1:1/dir
all="$(docker compose --env-file config/lab.env config --format json)"
alone="$(docker compose -f linkwarden/compose.yaml --env-file config/lab.env config --format json)"
lw="$(jq -c '.services.linkwarden' <<< "$alone")"
me="$(jq -c '.services["linkwarden-meilisearch"]' <<< "$alone")"
pg="$(jq -c '.services["linkwarden-postgresql"]' <<< "$alone")"
IMG_LW="$(jq -r '.image' <<< "$lw")"
IMG_ME="$(jq -r '.image' <<< "$me")"
IMG_PG="$(jq -r '.image' <<< "$pg")"
printf 'images: %s %s %s\n' "$IMG_LW" "$IMG_ME" "$IMG_PG"

lab_get() { grep -E "^$1=" config/lab.env | cut -d= -f2-; }
rt=traefik/dynamic/routers.yml
router_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} /^  [a-z]+:$/ {f=0} f' "$rt"; }
export -f router_block
export rt
mw_block() { awk -v r="$1" '$0 == "    " r ":" {f=1; next} /^    [a-z-]+:$/ {f=0} f' traefik/dynamic/middlewares.yml; }
export -f mw_block
bp=authentik/blueprints/homelab-apps.yaml

echo "--- static: images and identities"
check "Linkwarden is a pinned ghcr.io/linkwarden/linkwarden vX.Y.Z by digest" bash -c '[[ "$1" =~ ^ghcr\.io/linkwarden/linkwarden:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMG_LW"
check "Meilisearch is a pinned getmeili/meilisearch vX.Y.Z by digest" bash -c '[[ "$1" =~ ^getmeili/meilisearch:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]' _ "$IMG_ME"
check "PostgreSQL is the same pinned image as Authentik's" test "$IMG_PG" = "$(jq -r '.services["authentik-postgresql"].image' <<< "$all")"
check "root compose includes the three services with the same images" test "$(jq -r '[.services.linkwarden.image, .services["linkwarden-meilisearch"].image, .services["linkwarden-postgresql"].image] | join(" ")' <<< "$all")" = "$IMG_LW $IMG_ME $IMG_PG"
check "Linkwarden and Meilisearch run as LINKWARDEN_UID:GID 10007, PostgreSQL as 70:70 (never root, never 1000)" test "$(jq -r '.user' <<< "$lw") $(jq -r '.user' <<< "$me") $(jq -r '.user' <<< "$pg") $(lab_get LINKWARDEN_UID):$(lab_get LINKWARDEN_GID)" = "10007:10007 10007:10007 70:70 10007:10007"
check "the uid 10007 is not used by any other service in lab.env" test "$(grep -cE '^[A-Z_]+_UID=10007$' config/lab.env)" = 1
for s in lw me pg; do
  j="${!s}"
  check "$s: read-only root, cap_drop ALL, no cap_add, not privileged, no-new-privileges, memory limit" test "$(jq -c '[.read_only, .cap_drop, (.cap_add // []), (.privileged // false), (.security_opt | index("no-new-privileges:true") != null), (.mem_limit != null)]' <<< "$j")" = '[true,["ALL"],[],false,true,true]'
  check "$s: no published port, no docker.sock, no Traefik labels" bash -c '[ "$(jq ".ports // [] | length" <<< "$1")" = 0 ] && ! grep -q docker.sock <<< "$1" && [ "$(jq ".labels // {} | length" <<< "$1")" = 0 ]' _ "$j"
done
check "PostgreSQL reads its password through group 10007 (group_add), Linkwarden owns the file" test "$(jq -c '.group_add' <<< "$pg")" = '["10007"]'

echo "--- static: secrets and login"
check "no secret value in any environment: the database URL, NextAuth secret, Meilisearch key and client secret come from files" bash -c 'for j in "$@"; do jq -r ".environment // {} | keys[]" <<< "$j" | grep -Eqx "DATABASE_URL|NEXTAUTH_SECRET|MEILI_MASTER_KEY|AUTHENTIK_CLIENT_SECRET|POSTGRES_PASSWORD" && exit 1; done; exit 0' _ "$lw" "$me" "$pg"
check "the Linkwarden wrapper exports all four from /run/secrets and then execs the image entrypoint" bash -c 'e="$(jq -r ".entrypoint | join(\" \")" <<< "$1")"; for v in DATABASE_URL NEXTAUTH_SECRET MEILI_MASTER_KEY AUTHENTIK_CLIENT_SECRET; do grep -q "$v=" <<< "$e" || exit 1; done; grep -q "exec docker-entrypoint.sh" <<< "$e" && [ "$(jq -r "[.secrets[].source] | sort | join(\" \")" <<< "$1")" = "lw_meili_key lw_nextauth_secret lw_oidc_client_secret lw_pg_password" ]' _ "$lw"
check "the Meilisearch wrapper exports the key from its file and execs tini -- /bin/meilisearch" bash -c 'e="$(jq -r ".entrypoint | join(\" \")" <<< "$1")"; grep -qF "MEILI_MASTER_KEY=\"\$\$(cat /run/secrets/lw_meili_key)\"" <<< "$e" && grep -q "exec tini -- /bin/meilisearch" <<< "$e"' _ "$me"
check "PostgreSQL uses POSTGRES_PASSWORD_FILE" test "$(jq -r '.environment.POSTGRES_PASSWORD_FILE' <<< "$pg")" = /run/secrets/lw_pg_password
check "login: Linkwarden password login and self-registration are off, new SSO users allowed (Authentik gates them)" test "$(jq -r '[.environment.NEXT_PUBLIC_CREDENTIALS_ENABLED, .environment.NEXT_PUBLIC_DISABLE_REGISTRATION, .environment.DISABLE_NEW_SSO_USERS] | join(" ")' <<< "$lw")" = "false true false"
check "login: Authentik on, issuer https://auth.<domain>/application/o/linkwarden, client id linkwarden, NEXTAUTH_URL on links.<domain>" test "$(jq -r '[.environment.NEXT_PUBLIC_AUTHENTIK_ENABLED, .environment.AUTHENTIK_ISSUER, .environment.AUTHENTIK_CLIENT_ID, .environment.NEXTAUTH_URL] | join(" ")' <<< "$lw")" = "true https://auth.$DOMAIN_T/application/o/linkwarden linkwarden https://links.$DOMAIN_T/api/v1/auth"
check "manifest: the four Linkwarden secrets, required, with the owners and modes the containers need" bash -c 'm=config/secrets-manifest.tsv; grep -qP "^linkwarden/postgres-password\tlinkwarden/postgres-password\t10007:10007\t0440\tyes\traw$" $m && grep -qP "^linkwarden/nextauth-secret\tlinkwarden/nextauth-secret\t10007:10007\t0400\tyes\traw$" $m && grep -qP "^linkwarden/meili-key\tlinkwarden/meili-key\t10007:10007\t0400\tyes\traw$" $m && grep -qP "^linkwarden/oidc-client-secret\tauthentik/linkwarden-oidc-client-secret\t10002:10007\t0440\tyes\traw$" $m'
check "the Authentik worker mounts the client secret and exports it for the blueprint" bash -c 'w="$(jq -c ".services[\"authentik-worker\"]" <<< "$1")"; jq -r ".entrypoint | join(\" \")" <<< "$w" | grep -qF "LINKWARDEN_OIDC_CLIENT_SECRET=\"\$\$(cat /run/secrets/linkwarden_oidc_client_secret)\"" && jq -e ".secrets[] | select(.source == \"linkwarden_oidc_client_secret\")" <<< "$w"' _ "$all"

echo "--- static: networks, router, OIDC back-channel, Authentik"
check "Linkwarden is on proxy, oidc and linkwarden-internal; PostgreSQL and Meilisearch only on linkwarden-internal" test "$(jq -c '[.networks | keys[]]' <<< "$lw")|$(jq -c '[.networks | keys[]]' <<< "$me")|$(jq -c '[.networks | keys[]]' <<< "$pg")" = '["linkwarden-internal","oidc","proxy"]|["linkwarden-internal"]|["linkwarden-internal"]'
check "links router: the allowlist only (OIDC login, no forward auth), service linkwarden:3000" bash -c 'b="$(router_block linkwarden)"; grep -q "Host(\`links.{{ env \"DOMAIN\" }}\`)" <<< "$b" && grep -q "service: linkwarden$" <<< "$b" && [ "$(grep -A3 "middlewares:" <<< "$b" | grep -c -- "- ")" = 1 ] && grep -q -- "- lan-allowlist$" <<< "$b" && awk "/^  services:/{f=1} f" "$1" | grep -q "url: http://linkwarden:3000"' _ $rt
check "Traefik joins the oidc network with the alias auth.<domain>" test "$(jq -c '.services.traefik.networks.oidc.aliases' <<< "$all")" = "[\"auth.$DOMAIN_T\"]"
check "the Authentik router (and only it) uses oidc-allowlist; every other router keeps lan-allowlist" bash -c '[ "$(router_block authentik | grep -c -- "- oidc-allowlist")" = 1 ] && [ "$(grep -c -- "- oidc-allowlist" "$1")" = 1 ]' _ $rt
check "oidc-allowlist = the LAN, the tailnet and OIDC_SUBNET from lab.env, nothing else" bash -c '[ "$(mw_block oidc-allowlist | grep -E "^ +- " | tr -d " -" | sort | tr "\n" " ")" = "$(printf "%s\n" "$1" "$2" "$3" | sort | tr "\n" " ")" ]' _ "$(lab_get LAN_CIDR)" "$(lab_get TAILNET_CIDR)" "$(lab_get OIDC_SUBNET)"
check "blueprint: OAuth2 provider homelab-linkwarden, confidential, client id linkwarden, secret from the environment, one strict redirect" bash -c 'b="$(awk "/id: provider-linkwarden/{f=1} f&&/model: authentik_core.application/{exit} f" "$1")"; grep -q "client_type: confidential" <<< "$b" && grep -q "client_id: linkwarden$" <<< "$b" && grep -q "client_secret: !Env LINKWARDEN_OIDC_CLIENT_SECRET" <<< "$b" && [ "$(grep -c "matching_mode: strict" <<< "$b")" = 1 ] && grep -q "https://links.%s/api/v1/auth/callback/authentik" <<< "$b"' _ $bp
check "blueprint: the application is bound to homelab-admins and homelab-users (and no one else)" bash -c '[ "$(awk "/target: !KeyOf app-linkwarden/{getline; print}" "$1" | sort | tr -d " " | tr "\n" " ")" = "group:!KeyOfgroup-admins group:!KeyOfgroup-users " ]' _ $bp
check "blueprint: the household group homelab-users is created once and never given members by the file" bash -c 'b="$(awk "/id: group-users/{f=1} f&&/^  - model/{if(n++)exit} f" "$1")"; grep -q "state: created" <<< "$b" && grep -q "name: homelab-users" <<< "$b" && ! grep -q "users:" <<< "$b"' _ $bp
check "bootstrap.sh creates the oidc and linkwarden-internal networks and the three data directories" bash -c 'grep -q "ensure_network oidc --subnet" scripts/bootstrap.sh && grep -q "ensure_network linkwarden-internal --internal" scripts/bootstrap.sh && grep -q "linkwarden/data\" \"\$APPS_ROOT/linkwarden/meili\"" scripts/bootstrap.sh && grep -q "linkwarden/postgres" scripts/bootstrap.sh'
check "preflight.sh checks the networks, directories and ids, and that OIDC_SUBNET is in middlewares.yml" bash -c 'grep -q "authentik-auth oidc linkwarden-internal; do" scripts/preflight.sh && grep -q "linkwarden-postgres" scripts/preflight.sh && grep -q "LINKWARDEN_UID LINKWARDEN_GID KOFFAN_UID" scripts/preflight.sh && grep -q "OIDC_SUBNET 172.30.2.0/24" scripts/preflight.sh'
check "Homepage: the Linkwarden tile is live in Tools" bash -c 'awk "/^- Tools:/{f=1;next} /^- /{f=0} f" homepage/config/services.yaml | grep -q "href: https://links.{{HOMEPAGE_VAR_DOMAIN}}/"'
check "Dependabot watches /linkwarden and keeps Meilisearch on Linkwarden's pinned minor line" bash -c 'grep -q -- "- /linkwarden$" .github/dependabot.yml && grep -A1 "dependency-name: getmeili/meilisearch" .github/dependabot.yml | grep -q "semver-minor"'

if [ "$STATIC_ONLY" -eq 1 ]; then
  if [ "$fails" -gt 0 ]; then
    printf '\n%s static check(s) FAILED\n' "$fails"
    exit 1
  fi
  printf '\nAll static Linkwarden checks passed (use no flag for the container run)\n'
  exit 0
fi

# --------------------------------------------------------------------------------------------------------------------
echo "--- containers"
docker network create "$NET_PROXY" > /dev/null
docker network create --subnet "$(lab_get OIDC_SUBNET)" "$NET_OIDC" > /dev/null
docker network create --internal "$NET_INT" > /dev/null
for v in "${VOLS[@]}"; do
  docker volume rm "$v" > /dev/null 2>&1 || true # a volume left by an interrupted run would keep old data (and an old Meilisearch key)
  docker volume create "$v" > /dev/null
done
own() { docker run --rm --user 0 --entrypoint chown --mount "type=volume,src=$2,dst=/v,volume-nocopy" "$IMG_PG" "$1" /v; }
own 10007:10007 lwtest-data
own 10007:10007 lwtest-meili
own 70:70 lwtest-pg

# run_svc <name> <service json> <alias> <volume> <target> <networks...>: docker run from the rendered definition.
run_svc() {
  local name="$1" j="$2" alias="$3" vol="$4" tgt="$5" l k src
  shift 5
  local args=(--name "$name" --network "$1" --network-alias "$alias" --user "$(jq -r '.user' <<< "$j")" --read-only --cap-drop ALL
    --security-opt no-new-privileges:true --memory "$(jq -r '.mem_limit' <<< "$j")" --mount "type=volume,src=$vol,dst=$tgt,volume-nocopy")
  [ "$(jq -r '.shm_size // empty' <<< "$j")" = "" ] || args+=(--shm-size "$(jq -r '.shm_size' <<< "$j")")
  [ "$(jq -r '.pids_limit // empty' <<< "$j")" = "" ] || args+=(--pids-limit "$(jq -r '.pids_limit' <<< "$j")")
  while IFS= read -r l; do args+=(--group-add "$l"); done < <(jq -r '.group_add // [] | .[]' <<< "$j" | tr -d '\r')
  while IFS= read -r l; do args+=(--tmpfs "$l"); done < <(jq -r '.tmpfs // [] | .[]' <<< "$j" | tr -d '\r')
  while IFS= read -r l; do args+=(-e "$l"); done < <(jq -r '.environment // {} | to_entries[] | "\(.key)=\(.value)"' <<< "$j" | tr -d '\r')
  while IFS=$'\t' read -r k src; do
    args+=(--mount "type=bind,source=$here/secrets/${src#*/secrets/},target=/run/secrets/$k,readonly")
  done < <(jq -r --argjson top "$(jq -c '.secrets' <<< "$alone")" '.secrets // [] | .[] | [.source, $top[.source].file] | @tsv' <<< "$j" | tr -d '\r' | tr '\134' '/')
  local ep rest=()
  ep="$(jq -r '.entrypoint[0] // empty' <<< "$j")"
  [ -z "$ep" ] || args+=(--entrypoint "$ep")
  # compose config keeps "$$" escaped; compose itself turns it into "$" at run time, so the test does the same.
  # NUL-separated: the wrapper scripts span several lines, and a newline split would hand sh -c only their first line.
  # tr after jq: jq.exe on Windows writes every newline as CRLF (text mode), which would end each script line with a carriage return.
  mapfile -d '' -t rest < <(jq -j '(.entrypoint // [])[1:][], (.command // [])[] | gsub("[$][$]"; "$") + "\u0000"' <<< "$j" | tr -d '\r')
  docker create "${args[@]}" "$(jq -r '.image' <<< "$j")" "${rest[@]}" > /dev/null
  shift
  # The alias on EVERY network: Traefik (proxy) reaches the app as linkwarden:3000, like container_name does on the Pi.
  for n in "$@"; do docker network connect --alias "$alias" "$n" "$name"; done
  docker start "$name" > /dev/null
}
run_svc lwtest-pg "$pg" linkwarden-postgresql lwtest-pg /var/lib/postgresql/data "$NET_INT"
run_svc lwtest-meili "$me" linkwarden-meilisearch lwtest-meili /meili_data "$NET_INT"
for _ in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Health.Status}}' lwtest-pg 2> /dev/null)" = healthy ] && break; sleep 3; done
run_svc lwtest-app "$lw" linkwarden lwtest-data /data/data "$NET_INT" "$NET_PROXY" "$NET_OIDC"

# The stub for authentik-server (the Authentik router's service) and Traefik with the REAL flags and dynamic files.
stub_img="$(awk '$1=="FROM" && $2 ~ /^nginxinc\/nginx-unprivileged:/ {print $2}' it-tools/Dockerfile)"
printf 'server { listen 9000; location / { return 200 "AUTHENTIK-STUB"; } }\n' > "$stage/stub.conf"
chmod 644 "$stage/stub.conf"
acid="$(docker create --name lwtest-auth --network "$NET_PROXY" --network-alias authentik-server "$stub_img" nginx -g 'daemon off;')"
docker cp "$here/stub.conf" "$acid:/etc/nginx/conf.d/default.conf"
docker start lwtest-auth > /dev/null
timage="$(jq -r '.services.traefik.image' <<< "$all")"
mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$all" | tr -d '\r' |
  grep -Ev '^--(certificatesresolvers\.|entrypoints\.websecure\.http\.tls\.(certResolver|domains))')
flags+=(--entrypoints.websecure.http.tls=true)
mkdir -p "$stage/tr/dynamic"
cp traefik/dynamic/*.yml "$stage/tr/dynamic/"
# Widen ONLY lan-allowlist (its first range) so the test client on the host passes; oidc-allowlist stays exactly as committed.
sed -i '0,/- 10.0.0.0\/24/s//- 0.0.0.0\/0/' "$stage/tr/dynamic/middlewares.yml"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$here/tr/dynamic/test-k.pem" \
  -out "$here/tr/dynamic/test-c.pem" -days 2 -subj "/CN=*.${DOMAIN_T}" -addext "subjectAltName=DNS:*.${DOMAIN_T}" 2> /dev/null
printf 'tls:\n  certificates:\n    - certFile: /etc/traefik/dynamic/test-c.pem\n      keyFile: /etc/traefik/dynamic/test-k.pem\n' > "$stage/tr/dynamic/test-cert.yml"
chmod 644 "$stage/tr/dynamic/test-k.pem"
cid="$(docker create --name lwtest-traefik --network "$NET_PROXY" -p 127.0.0.1::443 -e DOMAIN="$DOMAIN_T" --tmpfs /letsencrypt "$timage" "${flags[@]}")"
docker network connect --alias "auth.$DOMAIN_T" "$NET_OIDC" "$cid"
docker cp "$here/tr/." "$cid:/etc/traefik"
docker start "$cid" > /dev/null

echo "--- Linkwarden containers"
healthy=0
for _ in $(seq 1 80); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' lwtest-app 2> /dev/null)" = healthy ] && {
    healthy=1
    break
  }
  sleep 3
done
check "Linkwarden becomes healthy with the rendered definition (migrations ran through the password file)" test "$healthy" = 1
check "Meilisearch and PostgreSQL are running" test "$(docker inspect -f '{{.State.Running}}' lwtest-meili lwtest-pg | sort -u)" = true
procs="$(docker exec lwtest-app sh -c 'for p in /proc/[0-9]*/status; do awk "/^Uid:|^CapEff:|^NoNewPrivs:/{printf \"%s \", \$2} END{print \"\"}" $p; done' 2> /dev/null | sort -u || true)"
check "every Linkwarden process (web, worker) is uid 10007 with no capability and no_new_privs set" bash -c '[ -n "$1" ] && ! grep -vq "^10007 0000000000000000 1 $" <<< "$1"' _ "$procs"
check "the root file system is read-only for Linkwarden and Meilisearch" bash -c '! docker exec lwtest-app sh -c "touch /data/apps/x" 2>/dev/null && ! docker exec lwtest-meili sh -c "touch /bin/x" 2>/dev/null'
check "the data directory is writable by 10007 (archives land there)" docker exec lwtest-app sh -c 'touch /data/data/.probe && rm /data/data/.probe'
check "the container command equals the image's CMD (the wrapper changes only the environment)" test "$(docker image inspect -f '{{json .Config.Cmd}}' "$IMG_LW" | jq -c .)" = "$(jq -c '.command | map(gsub("[$][$]"; "$"))' <<< "$lw")"
check "the password files never reach the environment (docker inspect has no secret value)" bash -c 'e="$(docker inspect lwtest-app lwtest-meili lwtest-pg -f "{{json .Config.Env}}")"; for f in "$1"/secrets/linkwarden/* "$1"/secrets/authentik/linkwarden-oidc-client-secret; do grep -qF "$(cat "$f")" <<< "$e" && exit 1; done; exit 0' _ "$stage"
prov="$(docker exec lwtest-app curl -s http://127.0.0.1:3000/api/v1/auth/providers 2> /dev/null || true)"
check "only the Authentik login is offered (no password login) [$(jq -c 'keys' <<< "$prov" 2> /dev/null)]" test "$(jq -c 'keys' <<< "$prov" 2> /dev/null)" = '["authentik"]'
si="$(jq -r '.authentik.signinUrl' <<< "$prov" 2> /dev/null | tr -d '\r' || true)"
check "the Authentik sign-in goes through links.<domain> [$si]" test "$si" = "https://links.$DOMAIN_T/api/v1/auth/signin/authentik"
# The login page takes its buttons from /api/v1/logins (AUTHENTIK_CUSTOM_NAME); next-auth's own provider list always says "Authentik".
lg="$(docker exec lwtest-app curl -s http://127.0.0.1:3000/api/v1/logins 2> /dev/null || true)"
lb="$(jq -c '[.buttonAuths[]? | .name] , .credentialsEnabled, .registrationDisabled' <<< "$lg" 2> /dev/null | tr -d '\r' | paste -sd' ' - || true)"
check "the login page offers one button, Home lab login, no password form and no sign-up [$lb]" test "$lb" = '["Home lab login"] "false" "true"'
check "Chromium (page archiving) runs inside the hardened container" docker exec lwtest-app sh -c 'b=$(ls -d /ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64)/chrome-headless-shell; timeout 40 "$b" --no-sandbox --headless --disable-gpu --user-data-dir=/tmp/chr --dump-dom about:blank 2>/dev/null | grep -q "<html"'

echo "--- through Traefik and the OIDC back-channel"
hostport="$(docker port "$cid" 443/tcp | head -n 1 | sed 's/.*://')"
ready=0
code=
for _ in $(seq 1 30); do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --connect-to "links.$DOMAIN_T:443:127.0.0.1:$hostport" "https://links.$DOMAIN_T/login" || true)"
  [ "$code" = 200 ] && ready=1 && break
  sleep 2
done
check "links.<domain> is served through the real Traefik router (200) [$code]" test "$ready" = 1
h="$(curl -skI --connect-to "links.$DOMAIN_T:443:127.0.0.1:$hostport" "https://links.$DOMAIN_T/login" | tr -d '\r')"
check "the shared security headers are on the Linkwarden response" bash -c 'grep -qi "^strict-transport-security: max-age=" <<< "$1" && grep -qi "^x-content-type-options: nosniff" <<< "$1" && grep -qi "^x-frame-options: deny" <<< "$1"' _ "$h"
bc="$(docker exec lwtest-app curl -sk -m 10 "https://auth.$DOMAIN_T/application/o/linkwarden/.well-known/openid-configuration" 2> /dev/null || true)"
check "from the oidc network, auth.<domain> resolves to Traefik and reaches the Authentik service (the back-channel passes) [$bc]" test "$bc" = AUTHENTIK-STUB
tip="$(docker inspect "$cid" -f "{{(index .NetworkSettings.Networks \"$NET_PROXY\").IPAddress}}")"
docker run -d --name lwtest-probe --network "$NET_PROXY" --add-host "auth.$DOMAIN_T:$tip" --entrypoint sleep "$IMG_PG" 120 > /dev/null
pc="$(docker exec lwtest-probe wget -q -S -T 10 --no-check-certificate -O /dev/null "https://auth.$DOMAIN_T/" 2>&1 | awk '/^ *HTTP\//{c=$2} END{print c}' || true)"
check "from the proxy network (not oidc), auth.<domain> is refused by oidc-allowlist (403) [$pc]" test "$pc" = 403

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Linkwarden checks passed\n'
