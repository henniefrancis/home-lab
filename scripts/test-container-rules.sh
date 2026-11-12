#!/usr/bin/env bash
# test-container-rules.sh - self-test of scripts/check-container-rules.sh (the ADR-018 guard, R19). Needs jq and docker (to render the real
# project once; nothing is started). The guard must pass on the real tree and must FAIL on each deliberately broken variant of it.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
for t in jq docker; do
  command -v "$t" > /dev/null || {
    echo "$t is required" >&2
    exit 2
  }
done
fails=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  fails=$((fails + 1))
}
check() {
  local d="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
T="$(mktemp -d -p "${CONTAINER_RULES_TEST_TMP:-.}" .container-rules-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/secrets/tailscale"
: > "$T/secrets/tailscale/tailscale.env"
export MSYS_NO_PATHCONV=1
APPS_ROOT="$(cd "$T" && { pwd -W 2> /dev/null || pwd; })" DOMAIN=lab.example.test ROUTE53_ZONE_ID=Z0000000000000000000 PI_LAN_IP=10.0.0.2 \
  RA_TRUST_ANCHOR_ARN=d RA_ACME_PROFILE_ARN=d RA_ACME_ROLE_ARN=d \
  docker compose --env-file config/lab.env config --format json | tr -d '\r' > "$T/base.json"
G=scripts/check-container-rules.sh
# mut <name> <jq filter>: write a mutated copy of the real project
mut() { jq -c "$2" "$T/base.json" | tr -d '\r' > "$T/$1.json"; }
# expect_fail <name> <description> <text the output must contain>
expect_fail() { check "$2" bash -c 'out="$(bash "$1" --json "$2" 2>&1)"; rc=$?; [ "$rc" -eq 1 ] && grep -qF -- "$3" <<< "$out"' _ "$G" "$T/$1.json" "$3"; }

check "the real project passes (every service non-root or in the register, caps as registered)" bash "$G" --json "$T/base.json"
check "the guard renders the project itself when given no file" bash "$G"

mut root '.services.linkwarden.user = "0:0"'
expect_fail root "a service running as root (0:0) outside the register is refused" "linkwarden: user must be numeric"
mut uid1000 '.services.homepage.user = "1000:1000"'
expect_fail uid1000 "uid 1000 (the Pi login user) is refused" "homepage: user must be numeric"
mut gid0 '.services["it-tools"].user = "10005:0"'
expect_fail gid0 "gid 0 is refused" "it-tools: user must be numeric"
mut nouser 'del(.services.homepage.user)'
expect_fail nouser "a service without any user: that is not in the register is refused" "homepage: user must be numeric"
mut named '.services.homepage.user = "node"'
expect_fail named "a user by name (not numeric) is refused" "homepage: user must be numeric"
mut nodrop '.services["authentik-server"].cap_drop = []'
expect_fail nodrop "a missing cap_drop ALL is refused" "authentik-server: cap_drop must contain ALL"
mut capadd '.services.homepage.cap_add = ["NET_BIND_SERVICE"]'
expect_fail capadd "a cap_add on a service the register does not list is refused" "homepage: cap_add NET_BIND_SERVICE is not allowed"
mut capmore '.services.pihole.cap_add += ["SYS_ADMIN"]'
expect_fail capmore "an extra capability on a register service is refused" "pihole: cap_add SYS_ADMIN is not allowed"
mut nnp '.services.traefik.security_opt = []'
expect_fail nnp "a missing no-new-privileges is refused" "traefik: security_opt must contain no-new-privileges:true"
mut nnpreg '.services.tailscale.security_opt = []'
expect_fail nnpreg "a missing no-new-privileges on a register service marked required is refused" "tailscale: security_opt must contain"
mut priv '.services.pihole.privileged = true'
expect_fail priv "privileged is refused, even for a register service" "pihole: must not be privileged"
mut newroot '.services.newapp = {"image":"x","cap_drop":["ALL"],"security_opt":["no-new-privileges:true"]}'
expect_fail newroot "a NEW service without a user (a would-be root start) is refused until ADR-018 lists it" "newapp: user must be numeric"
mut stale 'del(.services.portainer)'
expect_fail stale "a register entry whose service no longer exists is refused (no stale register)" "register service portainer does not exist"
check "the exempt entries (pihole, netdata, homeassistant) pass without no-new-privileges, as registered" bash -c 'jq -e "[.services.pihole, .services.netdata, .services.homeassistant | (.security_opt // []) | index(\"no-new-privileges:true\")] | all(. == null)" "$1" > /dev/null' _ "$T/base.json"
check "ra-helper (no user: in compose) is accepted only because its Dockerfile sets USER 10001:10001" bash -c 'grep -qE "^USER 10001:10001$" traefik/ra-helper/Dockerfile'
check "the register holds no value that is not a service, capability list, required or exempt" bash -c 'grep -vE "^(#|$)" config/adr-018-register.tsv | awk -F"\t" "NF != 4 || (\$3 != \"required\" && \$3 != \"exempt\") {bad=1} END{exit bad}"'

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll container-rule checks passed\n'
