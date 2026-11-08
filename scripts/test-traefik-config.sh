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
#   - the Docker socket is mounted only into socket-proxy, read-only, and the socket proxy has POST off
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
export ACME_CA_SERVER=https://127.0.0.1:1/dir

json="$(docker compose -f traefik/compose.yaml --env-file config/lab.env config --format json)"
image="$(jq -r '.services.traefik.image' <<< "$json")"
mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$json" | tr -d '\r')
printf 'image %s, %s static flags\n' "$image" "${#flags[@]}"

# --- static review of the rendered definition -------------------------------------------------------------------
check "no insecure API, debug or global insecureSkipVerify" bash -c '! printf "%s\n" "$@" | grep -Eiq "api\.insecure=true|api\.debug|insecureSkipVerify|:8080"' _ "${flags[@]}"
check "api.insecure=false and api.dashboard=true are explicit" bash -c 'printf "%s\n" "$@" | grep -qx -- "--api.insecure=false" && printf "%s\n" "$@" | grep -qx -- "--api.dashboard=true"' _ "${flags[@]}"
check "only ports 80 and 443 are published" test "$(jq -c '[.services.traefik.ports[].target] | sort' <<< "$json")" = "[80,443]"
check "docker.sock is mounted only into socket-proxy" test "$(jq -c '[.services | to_entries[] | select([.value.volumes[]? | select(.source == "/var/run/docker.sock")] | length > 0) | .key]' <<< "$json")" = '["socket-proxy"]'
check "docker.sock mount is read-only" test "$(jq -r '.services["socket-proxy"].volumes[] | select(.source == "/var/run/docker.sock") | .read_only' <<< "$json")" = "true"
check "socket proxy: POST=0, CONTAINERS=1, no other API group on" test "$(jq -c '.services["socket-proxy"].environment | to_entries | map(select(.value == "1") | .key) | sort' <<< "$json")" = '["CONTAINERS","EVENTS","PING","VERSION"]' -a "$(jq -r '.services["socket-proxy"].environment.POST' <<< "$json")" = "0"
check "traefik key is mounted only into ra-helper" test "$(jq -c '[.services | to_entries[] | select((.value.secrets // []) | map(.source) | index("ra_acme_key")) | .key]' <<< "$json")" = '["ra-helper"]'
check "no host key reference anywhere" bash -c '! printf "%s" "$1" | grep -q "host\.key"' _ "$json"
check "ra-helper shares traefik's network namespace" test "$(jq -r '.services["ra-helper"].network_mode' <<< "$json")" = "service:traefik"
check "ACME storage file is per CA environment" bash -c 'printf "%s\n" "$@" | grep -q -- "acme\.storage=/letsencrypt/acme-staging\.json"' _ "${flags[@]}"

check "tailscale keeps NoSNAT (real client source reaches the allowlist)" grep -q -- "snat-subnet-routes=false" tailscale/compose.yaml

# --- run the real image with the real flags ---------------------------------------------------------------------
cid="$(docker create -p 127.0.0.1::80 -p 127.0.0.1::443 \
  -e AWS_REGION=us-east-1 -e AWS_HOSTED_ZONE_ID="$ROUTE53_ZONE_ID" -e AWS_EC2_METADATA_SERVICE_ENDPOINT=http://127.0.0.1:9911 \
  --tmpfs /letsencrypt "$image" "${flags[@]}")"
# Stage the dynamic directory plus a dummy wildcard certificate (the only SAN is the wildcard, like the real one).
# The stage dir is inside the checkout and referenced relatively so docker.exe resolves it under Git Bash too.
stage="$(mktemp -d -p . .traefik-test.XXXXXX)"
trap 'rm -rf "$stage"; cleanup' EXIT
mkdir "$stage/dynamic"
cp traefik/dynamic/*.yml "$stage/dynamic/"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$stage/dynamic/test-k.pem" -out "$stage/dynamic/test-c.pem" \
  -days 2 -subj "/CN=*.${DOMAIN}" -addext "subjectAltName=DNS:*.${DOMAIN}" 2> /dev/null
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
docker cp "$stage/." "$cid:/etc/traefik"
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
  check "security headers are on that answer (HSTS 300 s, nosniff, frame deny)" bash -c 'r="$(probe "$1" "$2")"; grep -qi "^strict-transport-security: max-age=300; includesubdomains" <<< "$r" && grep -qi "^x-content-type-options: nosniff" <<< "$r" && grep -qi "^x-frame-options: DENY" <<< "$r"' _ "$port" "$DOMAIN"
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
check "healthcheck probes leave no access-log line (every access-log line has a real router, none is a ping)"   bash -c '! alog | jq -e "select(.DownstreamStatus != null and ((.RouterName // \"\") == \"\" or ((.RouterName // \"\") | test(\"ping\"))))" > /dev/null'
check "no file access log is configured (stdout and Docker rotation instead)" bash -c '! printf "%s
" "$@" | grep -q "accesslog.filepath"' _ "${flags[@]}"
check "stdout/stderr rotation is set on traefik (10m x 3)" test "$(jq -c '.services.traefik.logging.options' <<< "$json")" = '{"max-file":"3","max-size":"10m"}'

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll Traefik config checks passed\n'
