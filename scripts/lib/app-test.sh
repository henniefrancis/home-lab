#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154 # stage, here, all and alone are set by the sourcing test (see the list below)
# Helpers shared by the R19 app self-tests (scripts/test-koffan-config.sh, test-speedtest-config.sh, test-couchdb-config.sh,
# test-n8n-config.sh). Source it; do not execute it. It builds the same test rig as the Linkwarden test: the REAL Traefik image with the
# REAL flags, dynamic files and middlewares (only the allowlist is widened so the test client passes), a self-signed wildcard certificate,
# and a stub in place of authentik-server (the NGINX image already pinned in it-tools/Dockerfile). Dummy values only; nothing leaves the
# machine. The caller sets, before using these functions:
#   stage     the private scratch directory (inside the repo, removed by the caller's cleanup)
#   here      its path as Docker sees it (pwd -W on Git Bash)
#   all       the rendered root project (docker compose config --format json)
#   DOMAIN_T  the dummy domain
# and, in its cleanup, removes <prefix>-traefik and <prefix>-auth itself.

# app_test_stub_auth <prefix> <network>: starts <prefix>-auth on <network> with the alias authentik-server. Forward auth answers 302 to the
# fake authorize URL unless the request carries the cookie stub_session=ok (then 200 and a username header); any other outpost path answers
# OUTPOST-STUB.
app_test_stub_auth() {
  local prefix="$1" net="$2" img acid
  img="$(awk '$1=="FROM" && $2 ~ /^nginxinc\/nginx-unprivileged:/ {print $2}' it-tools/Dockerfile)"
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
  acid="$(docker create --name "$prefix-auth" --network "$net" --network-alias authentik-server --no-healthcheck "$img" nginx -g 'daemon off;')"
  docker cp "$here/stub.conf" "$acid:/etc/nginx/conf.d/default.conf"
  docker start "$prefix-auth" > /dev/null
}

# app_test_traefik <prefix> <network> [sed expression for routers.yml]...: starts <prefix>-traefik on <network> (port 443 published on
# 127.0.0.1, random) and sets APP_TEST_CID and APP_TEST_HOSTPORT. Extra arguments are sed expressions applied to the COPY of routers.yml
# (for example to point a service at a test container name).
app_test_traefik() {
  local prefix="$1" net="$2" timage expr
  shift 2
  local flags=()
  timage="$(jq -r '.services.traefik.image' <<< "$all")"
  mapfile -t flags < <(jq -r '.services.traefik.command[]' <<< "$all" | tr -d '\r' |
    grep -Ev '^--(certificatesresolvers\.|entrypoints\.websecure\.http\.tls\.(certResolver|domains))')
  flags+=(--entrypoints.websecure.http.tls=true)
  mkdir -p "$stage/tr/dynamic"
  cp traefik/dynamic/*.yml "$stage/tr/dynamic/"
  # Widen ONLY lan-allowlist (its first range) so the test client on the host passes; every other middleware stays as committed.
  sed -i '0,/- 10.0.0.0\/24/s//- 0.0.0.0\/0/' "$stage/tr/dynamic/middlewares.yml"
  for expr in "$@"; do sed -i "$expr" "$stage/tr/dynamic/routers.yml"; done
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$here/tr/dynamic/test-k.pem" \
    -out "$here/tr/dynamic/test-c.pem" -days 2 -subj "/CN=*.${DOMAIN_T}" -addext "subjectAltName=DNS:*.${DOMAIN_T}" 2> /dev/null
  printf 'tls:\n  certificates:\n    - certFile: /etc/traefik/dynamic/test-c.pem\n      keyFile: /etc/traefik/dynamic/test-k.pem\n' > "$stage/tr/dynamic/test-cert.yml"
  chmod 644 "$stage/tr/dynamic/test-k.pem"
  APP_TEST_CID="$(docker create --name "$prefix-traefik" --network "$net" -p 127.0.0.1::443 -e DOMAIN="$DOMAIN_T" --tmpfs /letsencrypt "$timage" "${flags[@]}")"
  docker cp "$here/tr/." "$APP_TEST_CID:/etc/traefik"
  docker start "$APP_TEST_CID" > /dev/null
  APP_TEST_HOSTPORT="$(docker port "$APP_TEST_CID" 443/tcp | head -n 1 | sed 's/.*://')"
}

# via <host> <path> [curl args]: prints "<code> <Location header>" for one request through Traefik; redirects are not followed.
via() {
  local h="$1" p="$2"
  shift 2
  curl -sk -o /dev/null -D - -w 'CODE %{http_code}
' --connect-to "$h:443:127.0.0.1:${APP_TEST_HOSTPORT}" "$@" "https://$h$p" 2> /dev/null |
    tr -d '\r' | awk '/^CODE /{c=$2} tolower($1)=="location:"{l=$2} END{print (c == "" ? "000" : c), l}' || true
}
# viab <host> <path> [curl args]: the response body.
viab() {
  local h="$1" p="$2"
  shift 2
  curl -sk --connect-to "$h:443:127.0.0.1:${APP_TEST_HOSTPORT}" "$@" "https://$h$p" || true
}
# viah <host> <path> [curl args]: the response headers (HEAD-like, body discarded; works for GET-only paths).
viah() {
  local h="$1" p="$2"
  shift 2
  curl -sk -o /dev/null -D - --connect-to "$h:443:127.0.0.1:${APP_TEST_HOSTPORT}" "$@" "https://$h$p" 2> /dev/null | tr -d '\r' || true
}

# app_test_run <name> <service json> <alias> <network> [docker run args]...: docker run from the RENDERED service definition (image, user,
# read-only, cap_drop, security_opt, limits, tmpfs, environment, secrets as read-only bind mounts, healthcheck), so a mistake in compose.yaml
# fails the test. Volumes are NOT taken from the definition (the caller passes --mount for named volumes). Command and entrypoint come
# from the definition too ("$$" is turned back into "$", as compose does).
# Needs `alone` (the stack's own rendered definition, for the secret file paths) from the caller.
app_test_run() {
  local name="$1" j="$2" alias="$3" net="$4" l k src ep
  shift 4
  local args=(--name "$name" --network "$net" --network-alias "$alias" --security-opt no-new-privileges:true)
  [ "$(jq -r '.user // empty' <<< "$j")" = "" ] || args+=(--user "$(jq -r '.user' <<< "$j")")
  [ "$(jq -r '.read_only // false' <<< "$j")" != true ] || args+=(--read-only)
  while IFS= read -r l; do args+=(--cap-drop "$l"); done < <(jq -r '.cap_drop // [] | .[]' <<< "$j" | tr -d '\r')
  while IFS= read -r l; do args+=(--cap-add "$l"); done < <(jq -r '.cap_add // [] | .[]' <<< "$j" | tr -d '\r')
  [ "$(jq -r '.mem_limit // empty' <<< "$j")" = "" ] || args+=(--memory "$(jq -r '.mem_limit' <<< "$j")")
  [ "$(jq -r '.pids_limit // empty' <<< "$j")" = "" ] || args+=(--pids-limit "$(jq -r '.pids_limit' <<< "$j")")
  [ "$(jq -r '.shm_size // empty' <<< "$j")" = "" ] || args+=(--shm-size "$(jq -r '.shm_size' <<< "$j")")
  while IFS= read -r l; do args+=(--tmpfs "$l"); done < <(jq -r '.tmpfs // [] | .[]' <<< "$j" | tr -d '\r')
  # Only variables with a value: `KEY=` would set an EMPTY variable where compose passes none.
  while IFS= read -r l; do args+=(-e "$l"); done < <(jq -r '.environment // {} | to_entries[] | select(.value != null) | "\(.key)=\(.value)"' <<< "$j" | tr -d '\r')
  while IFS=$'\t' read -r k src; do
    args+=(--mount "type=bind,source=$here/secrets/${src#*/secrets/},target=/run/secrets/$k,readonly")
  done < <(jq -r --argjson top "$(jq -c '.secrets // {}' <<< "$alone")" '.secrets // [] | .[] | [.source, $top[.source].file] | @tsv' <<< "$j" | tr -d '\r' | tr '\134' '/')
  ep="$(jq -r '.entrypoint[0] // empty' <<< "$j")"
  [ -z "$ep" ] || args+=(--entrypoint "$ep")
  local rest=()
  mapfile -d '' -t rest < <(jq -j '(.entrypoint // [])[1:][], (.command // [])[] | gsub("[$][$]"; "$") + "\u0000"' <<< "$j" | tr -d '\r')
  # The health check from the definition (the image's own check is used when the definition has none).
  if [ "$(jq -r '.healthcheck.test // empty | length' <<< "$j")" != "" ] && [ "$(jq -r '.healthcheck.test[0] // empty' <<< "$j")" = CMD-SHELL ]; then
    args+=(--health-cmd "$(jq -r '.healthcheck.test[1]' <<< "$j" | sed 's/[$][$]/$/g')" --health-interval 2s --health-retries 30 --health-start-period 5s)
  elif [ "$(jq -r '.healthcheck.test[0] // empty' <<< "$j")" = CMD ]; then
    args+=(--health-cmd "$(jq -r '.healthcheck.test[1:] | map(gsub("[$][$]"; "$")) | join(" ")' <<< "$j")" --health-interval 2s --health-retries 30 --health-start-period 5s)
  fi
  docker create "${args[@]}" "$@" "$(jq -r '.image' <<< "$j")" "${rest[@]}" > /dev/null
  docker start "$name" > /dev/null
}

# wait_healthy <container> [tries]: up to tries x 3 s for Health.Status healthy.
wait_healthy() {
  local i
  for i in $(seq 1 "${2:-60}"); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2> /dev/null)" = healthy ] && return 0
    [ "$i" -lt "${2:-60}" ] && sleep 3
  done
  return 1
}

# proc_ids <container>: one line per distinct "uid capEff nonewprivs" of the processes inside.
proc_ids() {
  docker exec "$1" sh -c 'for p in /proc/[0-9]*/status; do awk "/^Uid:|^CapEff:|^NoNewPrivs:/{printf \"%s \", \$2} END{print \"\"}" $p; done' 2> /dev/null | sort -u || true
}
