#!/usr/bin/env bash
# test-traefik-config.sh - offline self-test of the Traefik stack definition (milestone M3). Needs docker and jq.
#
# Renders traefik/compose.yaml with DUMMY values (no real domain, ARN or secret), then starts the pinned Traefik image
# with the exact static-config flags from the compose file and checks that:
#   - Traefik accepts every flag and the dynamic files (it exits at once on an unknown flag or a bad file)
#   - the container healthcheck passes
#   - nothing listens on :8080 and the insecure API / debug flags are absent
#   - plain HTTP gets a permanent redirect to HTTPS (308 for a POST)
#   - a TLS 1.1 handshake and an unknown or missing server name are refused (sniStrict, default option)
#   - there is no Docker provider, no docker.sock and no socket proxy anywhere; every router is a file (SEC-H2), the hosts
#     answer from the file provider, the break-glass drop-in switches a router on and off, one TLS option set (no 421), non-root
# The ACME CA is pointed at an unreachable address, so no certificate is requested from anyone.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose: $1, $2 expand in the child shell
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v docker > /dev/null || {
  echo "docker is required" >&2
  exit 2
}
command -v jq > /dev/null || {
  echo "jq is required" >&2
  exit 2
}
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: keep "container:/path" arguments intact

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

cid=""
cleanup() { [ -z "$cid" ] || docker rm -f "$cid" > /dev/null 2>&1 || true; }
trap cleanup EXIT

# Dummy runtime values; shell environment wins over --env-file in Compose.
export APPS_ROOT=/apps
export DOMAIN=lab.example.test
export ROUTE53_ZONE_ID=Z0000000000000000000
export RA_TRUST_ANCHOR_ARN=dummy-trust-anchor-arn
export RA_ACME_PROFILE_ARN=dummy-profile-arn
export RA_ACME_ROLE_ARN=dummy-role-arn
export PI_LAN_IP=10.0.0.2
export ACME_CA_SERVER=https://127.0.0.1:1/dir

json="$(docker compose -f traefik/compose.yaml --env-file config/lab.env config --format json)"
image="$(jq -r '.services.traefik.image' <<< "$json")"
mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$json" | tr -d '\r')
printf 'image %s, %s static flags\n' "$image" "${#flags[@]}"

# --- static review of the rendered definition -------------------------------------------------------------------
check "no insecure API, debug or global insecureSkipVerify" bash -c '! printf "%s\n" "$@" | grep -Eiq "api\.insecure=true|api\.debug|insecureSkipVerify|:8080"' _ "${flags[@]}"
check "api.insecure=false and api.dashboard=true are explicit" bash -c 'printf "%s\n" "$@" | grep -qx -- "--api.insecure=false" && printf "%s\n" "$@" | grep -qx -- "--api.dashboard=true"' _ "${flags[@]}"
check "only ports 80 and 443 are published" test "$(jq -c '[.services.traefik.ports[].target] | sort' <<< "$json")" = "[80,443]"
apps_tmp="$(mktemp -d -p . .traefik-test-apps.XXXXXX)"
mkdir -p "$apps_tmp/secrets/tailscale"
: > "$apps_tmp/secrets/tailscale/tailscale.env"
native_path() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf %s "$1"; fi; }
all="$(env APPS_ROOT="$(native_path "$PWD/$apps_tmp")" docker compose --env-file config/lab.env config --format json)"
allj() { printf '%s' "$all"; }
check "traefik root file system is read-only" test "$(jq -r '.services.traefik.read_only' <<< "$json")" = "true"
check "no Docker provider flag and no docker endpoint (SEC-H2)" bash -c '! printf "%s\n" "$@" | grep -Eiq "providers\.docker|docker\.sock|socket-proxy"' _ "${flags[@]}"
check "the file provider watches /etc/traefik/dynamic (routers, services and middlewares are all files)" bash -c 'printf "%s\n" "$@" | grep -qx -- "--providers.file.directory=/etc/traefik/dynamic" && printf "%s\n" "$@" | grep -qx -- "--providers.file.watch=true"' _ "${flags[@]}"
export -f allj; export all
check "only netdata and portainer mount docker.sock (SEC-H2, ADR-017): none in the traefik, authentik, homepage or tailscale stacks" bash -c '! allj | jq -r ".services | to_entries[] | select(.key != \"netdata\" and .key != \"portainer\") | .value.volumes[]? | .source" | grep -q "docker.sock"'
check "no socket-proxy service and no socket-proxy network remain" bash -c '! allj | jq -e "(.services | has(\"socket-proxy\")) or (.networks | has(\"socket-proxy\"))"'
check "no Traefik labels remain on any service (routers are files)" bash -c '! allj | jq -r ".services[] | .labels // {} | keys[]" | grep -q "^traefik\."'
check "published ports bind IPv4 only (no [::] listener, SEC-L2)" test "$(jq -c '[.services.traefik.ports[].host_ip] | unique' <<< "$json")" = '["0.0.0.0"]'
check "traefik runs as a non-root uid:gid from lab.env (SEC-L9)" test "$(jq -r '.services.traefik.user' <<< "$json")" = "10004:10004"
check "traefik lowers the unprivileged port start instead of holding NET_BIND_SERVICE" test "$(jq -r '.services.traefik.sysctls["net.ipv4.ip_unprivileged_port_start"]' <<< "$json")" = "80" -a "$(jq -c '.services.traefik.cap_add // []' <<< "$json")" = "[]" -a "$(jq -c '.services.traefik.cap_drop' <<< "$json")" = '["ALL"]'
check "traefik is on proxy, authentik-auth, oidc (the R17 OIDC back-channel) and n8n (R19) only" test "$(jq -c '[.services.traefik.networks | keys[]] | sort' <<< "$json" | tr -d '')" = '["authentik-auth","n8n","oidc","proxy"]'
check "the break-glass service and the whoami image are gone (it is a drop-in file now)" bash -c '! jq -e ".services | has(\"breakglass\")" <<< "$1" > /dev/null && ! grep -rq "traefik/whoami" traefik authentik homepage tailscale compose.yaml' _ "$json"
check "every third-party image in the stacks is pinned by digest (SEC-M5)" bash -c 'allj | jq -r ".services[] | select(.build == null) | .image" | grep -vq "@sha256:[0-9a-f]\{64\}$" && exit 1; exit 0'
check "only ONE TLS option set exists and no entrypoint selects another (421 regression, M5)" bash -c 'test "$(grep -c "^    [a-z]*:$" traefik/dynamic/tls.yml)" = 1 && grep -q "^    default:" traefik/dynamic/tls.yml && ! printf "%s\n" "$@" | grep -q "tls.options"' _ "${flags[@]}"
check "the dynamic directory has no hard-coded domain, only the DOMAIN template" bash -c '! grep -rEq "[a-z0-9-]+\.(com|net|org|co\.za)\b" traefik/dynamic traefik/breakglass'
check "every host rule uses the DOMAIN env template (a rule may continue on following lines, so every Host( is checked, comments aside)" bash -c '! grep -rhE "Host\(" traefik/dynamic traefik/breakglass | grep -v "^[[:space:]]*#" | grep -v "env \"DOMAIN\""'
check "breakglass_users secret file is owned for the traefik uid (manifest 10004)" bash -c 'grep -q "^traefik/breakglass-htpasswd.*10004:10004.*0400" config/secrets-manifest.tsv'
check "traefik key is mounted only into ra-helper" test "$(jq -c '[.services | to_entries[] | select((.value.secrets // []) | map(.source) | index("ra_acme_key")) | .key]' <<< "$json")" = '["ra-helper"]'
check "no host key reference anywhere" bash -c '! printf "%s" "$1" | grep -q "host\.key"' _ "$json"
check "ra-helper shares traefik's network namespace" test "$(jq -r '.services["ra-helper"].network_mode' <<< "$json")" = "service:traefik"
check "ACME storage file is per CA environment (acme-<ACME_ENV>.json from lab.env)" bash -c 'e="$1"; shift; [ -n "$e" ] && printf "%s\n" "$@" | grep -q -- "acme\.storage=/letsencrypt/acme-${e}\.json"' _ "$(sed -n 's/^ACME_ENV=//p' config/lab.env)" "${flags[@]}"

check "tailscale keeps NoSNAT (real client source reaches the allowlist)" grep -q -- "snat-subnet-routes=false" tailscale/compose.yaml
check "tailscale: cap_drop ALL with NET_ADMIN only (no NET_RAW), read-only root, no-new-privileges (SEC-M4)" bash -c 'allj | jq -e ".services.tailscale | (.cap_drop == [\"ALL\"]) and (.cap_add == [\"NET_ADMIN\"]) and (.read_only == true) and (.security_opt | index(\"no-new-privileges:true\"))"'

# --- run the real image with the real flags ---------------------------------------------------------------------
cid="$(docker create -p 127.0.0.1::80 -p 127.0.0.1::443 \
  --user "$(jq -r '.services.traefik.user' <<< "$json")" --sysctl net.ipv4.ip_unprivileged_port_start=80 \
  --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp \
  -e DOMAIN="$DOMAIN" -e AWS_REGION=us-east-1 -e AWS_HOSTED_ZONE_ID="$ROUTE53_ZONE_ID" -e AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911 \
  --tmpfs /letsencrypt:uid=10004,gid=10004,mode=0700 "$image" "${flags[@]}")"
# Stage the dynamic directory like deploy.sh fills it (a copy of traefik/dynamic/*.yml; break-glass is absent until switched on),
# plus a dummy wildcard certificate (the only SAN is the wildcard, like the real one) and a dummy break-glass secret.
# The stage dir is inside the checkout and referenced relatively so docker.exe resolves it under Git Bash too.
stage="$(mktemp -d -p . .traefik-test.XXXXXX)"
trap 'rm -rf "$stage" "$apps_tmp"; cleanup' EXIT
mkdir -p "$stage/dynamic" "$stage/run-secrets"
cp traefik/dynamic/*.yml "$stage/dynamic/"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$stage/dynamic/test-k.pem" -out "$stage/dynamic/test-c.pem" \
  -days 2 -subj "/CN=*.${DOMAIN}" -addext "subjectAltName=DNS:*.${DOMAIN}" 2> /dev/null
chmod 644 "$stage/dynamic/test-k.pem" # the container runs as a non-root uid
cat > "$stage/dynamic/test-cert.yml" << 'EOF'
tls:
  certificates:
    - certFile: /etc/traefik/dynamic/test-c.pem
      keyFile: /etc/traefik/dynamic/test-k.pem
EOF
cat > "$stage/dynamic/test-router.yml" << 'EOF'
http:
  routers:
    probe:
      rule: Host(`x.lab.example.test`)
      entryPoints: [websecure]
      service: noop@internal
      middlewares: [lan-allowlist@file]
EOF
printf 'admin:%s\n' "$(openssl passwd -apr1 test-only-not-a-secret)" > "$stage/run-secrets/breakglass_users"
# N2 root cause: `docker cp <dir>` keeps the host owner and mode of what it copies, and mktemp -d is mode 0700. On a Linux CI
# runner (uid 1001) /etc/traefik and /etc/traefik/dynamic therefore arrived as 1001:1001 0700 and the uid 10004 Traefik died
# with "stat /etc/traefik/traefik.toml: permission denied" (and, with cap_drop ALL, even root could not clean up files owned
# by 1001). Docker Desktop on Windows hides this, because everything there is root. The Pi is unaffected: deploy.sh installs the
# real directory root-owned 0755. put() streams a tar with root:root owners and readable modes, so the result is the same on
# every host. tar needs GNU options (Git Bash and Linux have them).
put() { # put <host dir> <absolute container dir>: contents arrive as root:root, directories 0755, files 0644/0755
  tar -C "$1" --owner=0 --group=0 --numeric-owner --mode='u=rwX,go=rX' --transform "s,^\.,${2#/}," -cf - . | docker cp - "$cid:/"
}
put "$stage/dynamic" /etc/traefik/dynamic
put "$stage/run-secrets" /run/secrets
docker start "$cid" > /dev/null
sleep 8; [ "${TEST_DEBUG:-0}" != 1 ] || docker logs "$cid" 2>&1 | tail -5

check "traefik is running (flags and dynamic files accepted)" test "$(docker inspect -f '{{.State.Running}}' "$cid")" = "true"
hc="$(jq -c '.services.traefik.healthcheck.test[1:]' <<< "$json")"
mapfile -t hcargs < <(jq -r '.services.traefik.healthcheck.test[1:][]' <<< "$json" | tr -d '\r')
check "container healthcheck passes: ${hc}" docker exec "$cid" "${hcargs[@]}"
check "nothing listens on :8080" bash -c '! docker exec "$1" netstat -tln | grep -q ":8080 "' _ "$cid"
check "file provider loaded without errors" bash -c '! docker logs "$1" 2>&1 | grep -E "\"level\":\"error\"" | grep -Eq "file|middleware|tls"' _ "$cid"
hport="$(docker port "$cid" 80/tcp | head -n 1 | sed 's/.*://')"
check "POST over HTTP is answered 308 to https" bash -c 'curl -si -X POST "http://127.0.0.1:$1/x" | head -n 1 | grep -q " 308 "' _ "$hport"
check "GET over HTTP is answered with a permanent redirect (301)" bash -c 'curl -si "http://127.0.0.1:$1/x" | head -n 1 | grep -q " 301 "' _ "$hport"

if command -v openssl > /dev/null; then
  port="$(docker port "$cid" 443/tcp | head -n 1 | sed 's/.*://')"
  check "wildcard name is served (TLS 1.2 or newer)" bash -c 'echo | openssl s_client -connect "127.0.0.1:$1" -servername "x.$2" 2>&1 | grep -q "subject=CN *= *\*\.$2"' _ "$port" "$DOMAIN"
  check "TLS 1.1 is refused" bash -c '! echo | openssl s_client -connect "127.0.0.1:$1" -servername "x.$2" -tls1_1 2>&1 | grep -q "Protocol *: TLSv1.1"' _ "$port" "$DOMAIN"
  check "apex name is refused (sniStrict, not covered by the wildcard)" bash -c 'echo | openssl s_client -connect "127.0.0.1:$1" -servername "$2" 2>&1 | grep -qi "unrecognized name\|alert"' _ "$port" "$DOMAIN"
  check "no server name is refused" bash -c 'echo | openssl s_client -connect "127.0.0.1:$1" -noservername 2>&1 | grep -qi "unrecognized name\|alert"' _ "$port"
  probe() { curl -ski --resolve "x.$2:$1:127.0.0.1" "https://x.$2:$1/" | tr -d '\r'; }
  export -f probe
  check "lan-allowlist answers 403 to a non-LAN source" bash -c 'probe "$1" "$2" | head -n 1 | grep -q " 403 "' _ "$port" "$DOMAIN"
  sts="$(sed -nE 's/^[[:space:]]+stsSeconds:[[:space:]]*([0-9]+).*/\1/p' traefik/dynamic/middlewares.yml)"
  check "security headers are on that answer (HSTS max-age=${sts:-?} from middlewares.yml, nosniff, frame deny)" bash -c 'r="$(probe "$1" "$2")"; [ -n "$3" ] && grep -qi "^strict-transport-security: max-age=$3; includesubdomains" <<< "$r" && grep -qi "^x-content-type-options: nosniff" <<< "$r" && grep -qi "^x-frame-options: DENY" <<< "$r"' _ "$port" "$DOMAIN" "$sts"
  # --- routers from files (SEC-H2) ---------------------------------------------------------------------------------
  code() { curl -sk -o /dev/null -w '%{http_code}' --resolve "$2:$1:127.0.0.1" "https://$2:$1/" 2> /dev/null; }
  export -f code
  check "a spoofed X-Forwarded-For from a LAN address does not pass the allowlist (S21): still 403" bash -c 'c="$(curl -sk -o /dev/null -w "%{http_code}" --resolve "x.$2:$1:127.0.0.1" -H "X-Forwarded-For: 10.0.0.5" -H "X-Real-Ip: 10.0.0.5" "https://x.$2:$1/")"; [ "$c" = 403 ]' _ "$port" "$DOMAIN"
  check "traefik runs as uid 10004, not root (SEC-L9)" test "$(docker exec "$cid" id -u)" = "10004"
  check "ports 80 and 443 are bound by the non-root process (sysctl, no capability)" bash -c '[ "$(docker exec "$1" cat /proc/sys/net/ipv4/ip_unprivileged_port_start)" = 80 ]' _ "$cid"
  for h in traefik auth dashboard; do
    check "router for $h.<domain> exists (file provider): the allowlist answers 403 to a non-LAN source" test "$(code "$port" "$h.$DOMAIN")" = "403"
  done
  check "an unrouted host has no router: bare 404" test "$(code "$port" "nothing.$DOMAIN")" = "404"
  check "a request whose SNI and Host differ is NOT 421 with one TLS option set (M5 regression)" bash -c 'c="$(curl -sk -o /dev/null -w "%{http_code}" --resolve "x.$2:$1:127.0.0.1" -H "Host: traefik.$2" "https://x.$2:$1/")"; [ "$c" != 421 ] && [ "$c" = 403 ]' _ "$port" "$DOMAIN"
  check "break-glass is OFF by default: bg-traefik.<domain> has no router (404, SEC-L3)" test "$(code "$port" "bg-traefik.$DOMAIN")" = "404"
  # what breakglass.sh does: install -m 0644 (root-owned) into the watched directory
  bgstage="$stage/bg"
  mkdir -p "$bgstage"
  cp traefik/breakglass/bg-traefik.yml "$bgstage/"
  put "$bgstage" /etc/traefik/dynamic
  sleep 5
  [ "${TEST_DEBUG:-0}" != 1 ] || docker logs "$cid" 2>&1 | tail -4
  check "break-glass ON (drop-in file copied): the router exists and the allowlist answers first (403)" test "$(code "$port" "bg-traefik.$DOMAIN")" = "403"
  docker exec -u 0 "$cid" rm -f /etc/traefik/dynamic/bg-traefik.yml
  sleep 3
  check "break-glass OFF again (file removed): the router is gone (404)" test "$(code "$port" "bg-traefik.$DOMAIN")" = "404"
  check "no error about the template or the file provider in the log" bash -c '! docker logs "$1" 2>&1 | grep "\"level\":\"error\"" | grep -Eiq "template|provider|router|service"' _ "$cid"
else
  echo "SKIP  TLS checks (openssl not found)"
fi

# --- access log: JSON on stdout, internal routers included, healthcheck probes not logged ---------------------------
alog() { docker logs "$cid" 2> /dev/null | tr -d '\r'; }
export -f alog
export cid
check "access log is JSON in the container log and records the 308 redirect (internal router)" bash -c 'alog | jq -e "select(.RouterName == \"web-to-websecure@internal\" and .DownstreamStatus == 308)"'
check "access log records the 403 of the probe router" bash -c 'alog | jq -e "select(.RouterName == \"probe@file\" and .DownstreamStatus == 403)"'
docker exec "$cid" "${hcargs[@]}" > /dev/null 2>&1 || true
sleep 3
check "healthcheck probes leave no access-log line (no line comes from loopback and none is a ping router)" bash -c '! alog | jq -e "select(.DownstreamStatus != null and (.ClientHost == \"127.0.0.1\" or ((.RouterName // \"\") | test(\"ping\"))))" > /dev/null'
check "no file access log is configured (stdout and Docker rotation instead)" bash -c '! printf "%s\n" "$@" | grep -q "accesslog.filepath"' _ "${flags[@]}"
check "stdout/stderr rotation is set on traefik (10m x 3)" test "$(jq -c '.services.traefik.logging.options' <<< "$json")" = '{"max-file":"3","max-size":"10m"}'

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  # Make a CI failure diagnosable from the log alone: the container state and its last output (the JSON log has no secrets:
  # every value in this test is a dummy).
  if [ -n "$cid" ]; then
    echo "--- container state"
    docker inspect -f 'running={{.State.Running}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' "$cid" 2>&1 || true
    echo "--- docker logs (last 60 lines)"
    docker logs "$cid" 2>&1 | tail -n 60 || true
  fi
  exit 1
fi
printf '\nAll Traefik config checks passed\n'
