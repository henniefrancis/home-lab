#!/usr/bin/env bash
# test-fetch-secrets.sh - tests for scripts/fetch-secrets.sh with a mock `aws` (no network, no real secrets).
#
# Part A (any user): config/secrets-manifest.tsv agrees with terraform/edge/ssm.tf.
# Part B (needs root, uses temp dirs only; run via sudo or in a throwaway container): the fetch behaviour:
#   files, owners, modes, placeholder fail-closed, AWS failure, interrupted run leaves no staging, atomic swap,
#   release pruning, dry-run, and that no secret value ever reaches the output.
# CI runs it as: sudo -E bash scripts/test-fetch-secrets.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
check() { # check <name> <command...>
  local n="$1"
  shift
  if "$@"; then ok "$n"; else bad "$n"; fi
}

# ------------------------------------------------------------------ Part A
manifest_secrets="$(grep -vE '^(#|$)' "$REPO/config/secrets-manifest.tsv" | cut -f1 | grep -v '^config/' | sort)"
manifest_config="$(grep -vE '^(#|$)' "$REPO/config/secrets-manifest.tsv" | cut -f1 | grep '^config/' | sort)"
tf_secrets="$(grep -E '^[[:space:]]+"[a-z0-9-]+/[a-z0-9-]+"[[:space:]]*=[[:space:]]*"' "$REPO/terraform/edge/ssm.tf" | sed -E 's/^[[:space:]]+"([^"]+)".*/\1/' | grep -v '^config/' | sort)"
tf_config="$(grep -E '^[[:space:]]+"config/[a-z0-9-]+"[[:space:]]*=' "$REPO/terraform/edge/ssm.tf" | sed -E 's/^[[:space:]]+"([^"]+)".*/\1/' | sort)"
check "manifest SecureStrings == ssm.tf secure_params" test "$manifest_secrets" = "$tf_secrets"
check "manifest config rows == ssm.tf config_params" test "$manifest_config" = "$tf_config"
check "manifest has a tab-separated row per parameter" test "$(grep -vcE '^(#|$)' "$REPO/config/secrets-manifest.tsv")" -ge 11

if [ "$(id -u)" -ne 0 ]; then
  echo "SKIP - Part B needs root (run: sudo -E bash $0)"
  [ "$fails" -eq 0 ] && exit 0 || exit 1
fi
command -v jq > /dev/null || {
  echo "jq is required for Part B"
  exit 1
}

# ------------------------------------------------------------------ Part B
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc/pki"
chmod 700 "$T/etc"
acct="$(printf '%012d' 7)"
ta="arn:aws:rolesanywhere:af-south-1:${acct}:trust-anchor/aaaaaaaa-0000-0000-0000-00000000000a"
pr="arn:aws:rolesanywhere:af-south-1:${acct}:profile/aaaaaaaa-0000-0000-0000-00000000000b"
ro="arn:aws:iam::${acct}:role/home-lab-pi-host"
printf 'AWS_REGION=af-south-1\nRA_TRUST_ANCHOR_ARN=%s\nRA_HOST_PROFILE_ARN=%s\nRA_HOST_ROLE_ARN=%s\n' "$ta" "$pr" "$ro" > "$T/etc/aws.env"
chmod 600 "$T/etc/aws.env"
: > "$T/etc/pki/host.crt"
: > "$T/etc/pki/host.key"

cat > "$T/bin/aws" << 'MOCK'
#!/usr/bin/env bash
case "$*" in *"ssm get-parameters-by-path"*) ;; *) echo "unexpected aws call" >&2; exit 9 ;; esac
if [ -n "${MOCK_AWS_FAIL:-}" ]; then echo "An error occurred (AccessDeniedException): not authorized" >&2; exit 254; fi
if [ -n "${MOCK_AWS_SLEEP:-}" ]; then touch "$MOCK_AWS_MARK"; sleep "$MOCK_AWS_SLEEP"; fi
cat "$MOCK_AWS_JSON"
MOCK
chmod +x "$T/bin/aws"
export PATH="$T/bin:$PATH"

V_SK="fixture-secret-key-AAAA1111"
V_PG="fixture-pg-password-BBBB2222"
# shellcheck disable=SC2016 # a literal bcrypt-style fixture, nothing to expand
V_HT='admin:$2y$05$fixturehashCCCC3333'
V_TS="tskey-auth-fixtureDDDD4444"
V_DOM="lab.example.test"
V_ZONE="ZFIXTURE5555"
PH="UNSET-set-via-set-secret"

# mkjson <out> [name=value ...]: overrides per name; type String for config/*, SecureString otherwise.
mkjson() {
  local out="$1"
  shift
  local -A val=(
    [authentik/secret-key]="$V_SK" [authentik/postgres-password]="$V_PG" [authentik/bootstrap-password]="$PH"
    [traefik/breakglass-htpasswd]="$V_HT" [tailscale/auth-key]="$PH" [homepage/authentik-token]="$PH"
    [config/domain]="$V_DOM" [config/route53-zone-id]="$V_ZONE" [config/ra-trust-anchor-arn]="$ta"
    [config/ra-acme-profile-arn]="$pr" [config/ra-acme-role-arn]="$ro"
  )
  local kv k
  for kv in "$@"; do
    k="${kv%%=*}"
    if [ "${kv#*=}" = "@@drop" ]; then unset "val[$k]"; else val[$k]="${kv#*=}"; fi
  done
  for k in "${!val[@]}"; do
    jq -n --arg n "/home-lab/$k" --arg v "${val[$k]}" --arg t "$([[ $k == config/* ]] && echo String || echo SecureString)" \
      '{Name:$n, Type:$t, Value:$v, Version:1}'
  done | jq -s '{Parameters: .}' > "$out"
}

AR="$T/apps"
mkdir -p "$AR"
FETCH=(bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR" --etc-dir "$T/etc")
export MOCK_AWS_JSON="$T/params.json"
rc=0
# shellcheck disable=SC2119,SC2120 # extra args are optional
run() { # run <extra args...>; sets rc, output in $T/out.log
  rc=0
  "${FETCH[@]}" "$@" > "$T/out.log" 2>&1 || rc=$?
}
no_values_in_output() {
  local v
  for v in "$V_SK" "$V_PG" "$V_HT" "$V_TS" "$V_DOM" "$V_ZONE" "$ta" "$pr" "$ro" "$acct"; do
    grep -qF -- "$v" "$T/out.log" && return 1
  done
  return 0
}
no_staging() { [ -z "$(find "$AR/.secrets.d" -maxdepth 1 -name '.staging-*' 2> /dev/null)" ] && [ -z "$(find /run -maxdepth 1 -name 'home-lab-fetch.*' 2> /dev/null)" ]; }
attrs() { stat -c '%u:%g %a' "$AR/secrets/$1"; }

# 1. first run: a real empty dir sits at secrets/ (as created by bootstrap) and must become the symlink
mkdir -p "$AR/secrets"
chmod 700 "$AR/secrets"
mkjson "$T/params.json"
run
check "happy path exits 0" test "$rc" -eq 0
check "secrets became a symlink to a release" test -L "$AR/secrets"
check "authentik/secret-key 1000:1000 0400" test "$(attrs authentik/secret-key)" = "1000:1000 400"
check "authentik/postgres-password 1000:1000 0400" test "$(attrs authentik/postgres-password)" = "1000:1000 400"
check "breakglass-htpasswd 0:0 0400" test "$(attrs traefik/breakglass-htpasswd)" = "0:0 400"
check "secret-key content exact (no trailing newline)" test "$(cat "$AR/secrets/authentik/secret-key"; echo x)" = "${V_SK}x"
check "optional placeholder omitted (bootstrap-password)" test ! -e "$AR/secrets/authentik/bootstrap-password"
check "optional placeholder omitted (homepage token)" test ! -e "$AR/secrets/homepage/authentik-token"
check "tailscale.env is an empty 0:0 0600 file while UNSET" test "$(attrs tailscale/tailscale.env)" = "0:0 600" -a ! -s "$AR/secrets/tailscale/tailscale.env"
check "runtime.env 0:0 0600" test "$(attrs runtime.env)" = "0:0 600"
check "runtime.env has the 5 variables" test "$(grep -cE '^(DOMAIN|ROUTE53_ZONE_ID|RA_TRUST_ANCHOR_ARN|RA_ACME_PROFILE_ARN|RA_ACME_ROLE_ARN)=' "$AR/secrets/runtime.env")" -eq 5
check "no secret value or ARN in the script output" no_values_in_output
check "no staging dir left behind" no_staging
check "aws-config is root 0600 and has no key material" test "$(stat -c '%u %a' "$T/etc/aws-config")" = "0 600"
first="$(readlink "$AR/secrets")"

# 2. real Tailscale key -> TS_AUTHKEY line
mkjson "$T/params.json" "tailscale/auth-key=$V_TS"
run
check "run with a real Tailscale key exits 0" test "$rc" -eq 0
check "tailscale.env holds TS_AUTHKEY=..." test "$(cat "$AR/secrets/tailscale/tailscale.env")" = "TS_AUTHKEY=$V_TS"
check "no values in output (2)" no_values_in_output
second="$(readlink "$AR/secrets")"
check "second run published a new release" test "$first" != "$second"

# 3. placeholder in a required parameter fails closed
mkjson "$T/params.json" "authentik/postgres-password=$PH"
run
check "required placeholder exits 4" test "$rc" -eq 4
check "failure names the parameter" grep -q 'postgres-password' "$T/out.log"
check "failure leaves the previous release in place" test "$(readlink "$AR/secrets")" = "$second"
check "previous secret content untouched" test "$(cat "$AR/secrets/authentik/postgres-password"; echo x)" = "${V_PG}x"
check "no values in output (3)" no_values_in_output
check "no staging dir after failure" no_staging

# 4. missing required parameter, wrong type, unsafe env value
mkjson "$T/params.json" "config/domain=@@drop"
run
check "missing required parameter exits 4" test "$rc" -eq 4
mkjson "$T/params.json"
jq '(.Parameters[] | select(.Name == "/home-lab/authentik/secret-key") | .Type) = "String"' "$T/params.json" > "$T/p2.json" && mv "$T/p2.json" "$T/params.json"
run
check "a secret stored as plain String exits 4" test "$rc" -eq 4
mkjson "$T/params.json" "config/domain=has space"
run
check "unsafe env value exits 4" test "$rc" -eq 4
check "release unchanged after validation failures" test "$(readlink "$AR/secrets")" = "$second"
check "no staging dir after validation failures" no_staging

# 5. AWS failure
mkjson "$T/params.json"
MOCK_AWS_FAIL=1 run
check "AWS failure exits 3" test "$rc" -eq 3
check "AWS failure leaves the release in place" test "$(readlink "$AR/secrets")" = "$second"
check "no staging dir after AWS failure" no_staging

# 6. interrupted run (SIGTERM during the AWS call) cleans up
export MOCK_AWS_MARK="$T/mark"
rm -f "$MOCK_AWS_MARK"
MOCK_AWS_SLEEP=30 "${FETCH[@]}" > "$T/out.log" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
  [ -e "$MOCK_AWS_MARK" ] && break
  sleep 0.1
done
check "staging exists while a fetch is in flight" test -n "$(find "$AR/.secrets.d" -maxdepth 1 -name '.staging-*')"
pkill -TERM -P "$pid" 2> /dev/null || true
kill -TERM "$pid" 2> /dev/null || true
wait "$pid" 2> /dev/null || true
check "interrupted run leaves no staging or tmpfs dirs" no_staging
check "interrupted run leaves the release in place" test "$(readlink "$AR/secrets")" = "$second"

# 7. pruning keeps at most 3 releases and the current one
mkjson "$T/params.json"
for _ in 1 2 3 4; do run; done
check "pruning keeps 3 releases" test "$(find "$AR/.secrets.d" -maxdepth 1 -name 'release-*' | wc -l)" -eq 3
check "current release still exists" test -d "$AR/secrets/."

# 8. dry-run on a fresh root publishes nothing
AR2="$T/apps2"
mkdir -p "$AR2"
rc=0
bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR2" --etc-dir "$T/etc" --dry-run > "$T/out.log" 2>&1 || rc=$?
check "dry-run exits 0" test "$rc" -eq 0
check "dry-run publishes nothing" test ! -e "$AR2/secrets"
check "dry-run leaves no staging" test -z "$(find "$AR2/.secrets.d" -maxdepth 1 -name '.staging-*')"

# 9. bad manifest rows are rejected before any AWS call
printf 'authentik/secret-key\tauthentik/secret-key\t1000:1000\t0777x\tyes\traw\n' > "$T/bad.tsv"
rc=0
bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR2" --etc-dir "$T/etc" --manifest "$T/bad.tsv" > "$T/out.log" 2>&1 || rc=$?
check "bad manifest mode exits 4" test "$rc" -eq 4
printf 'authentik/secret-key\t../escape\t1000:1000\t0400\tyes\traw\n' > "$T/bad.tsv"
rc=0
bash "$REPO/scripts/fetch-secrets.sh" --apps-root "$AR2" --etc-dir "$T/etc" --manifest "$T/bad.tsv" > "$T/out.log" 2>&1 || rc=$?
check "manifest path traversal exits 4" test "$rc" -eq 4

# 10. aws.env with loose permissions is refused
chmod 644 "$T/etc/aws.env"
run
check "aws.env mode 0644 is refused" test "$rc" -ne 0
chmod 600 "$T/etc/aws.env"

echo
if [ "$fails" -eq 0 ]; then
  echo "fetch-secrets tests: all checks passed"
else
  echo "fetch-secrets tests: $fails FAILED"
  exit 1
fi
