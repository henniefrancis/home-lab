#!/usr/bin/env bash
# test-alert.sh - offline self-test of the K4 alert path: scripts/served-cert-check.sh, scripts/alert.sh and scripts/lib/alert.sh.
# Needs openssl and bash. No root, no AWS, no network beyond 127.0.0.1:
#   - served-cert-check.sh against a local `openssl s_server`: healthy, under 21 days (WARN), under 7 days (FAIL), expired, wrong name, nothing listening
#   - alert.sh with a MOCK aws that records its arguments: test, rate limit (one per key per day), missing topic, check, unit-failed
# The mock aws is placed first on PATH, real credentials and config are disabled, and the mock is PROVED before use.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
command -v openssl > /dev/null || {
  echo "openssl is required" >&2
  exit 2
}
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true

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

T="$(mktemp -d)"
SRV_PID=""
cleanup() {
  [ -z "$SRV_PID" ] || kill "$SRV_PID" 2> /dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

# ---------------------------------------------------------------- served-cert-check.sh
mkcert() { # mkcert <name> <days> <dns name>: self-signed certificate with a SAN (a config file: Git Bash rewrites "/CN=" as a path)
  cat > "$T/$1.cnf" << CNF
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=$3
[ext]
subjectAltName=DNS:$3
CNF
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/$1.key" -out "$T/$1.crt" -days "$2" -config "$T/$1.cnf" 2> /dev/null
}
NEXT_PORT=18443
next_port() { # set PORT to a local port nobody listens on, never reusing one (a killed server may linger on Windows)
  while [ "$NEXT_PORT" -lt 18700 ]; do
    PORT="$NEXT_PORT"
    NEXT_PORT=$((NEXT_PORT + 1))
    (exec 3<> "/dev/tcp/127.0.0.1/$PORT") 2> /dev/null || return 0
  done
  return 1
}
serve() { # serve <name>: s_server for that certificate on a fresh port ($PORT) until stopped (a new port each time: a killed server may linger on Windows)
  [ -z "$SRV_PID" ] || kill "$SRV_PID" 2> /dev/null || true
  next_port || return 1
  openssl s_server -quiet -accept "$PORT" -cert "$T/$1.crt" -key "$T/$1.key" > /dev/null 2>&1 &
  SRV_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    (exec 3<> "/dev/tcp/127.0.0.1/$PORT") 2> /dev/null && return 0
    sleep 0.3
  done
  return 1
}
served() { # served <expected exit code> <description> [env assignments...]
  local want="$1" desc="$2" rc=0
  shift 2
  env "$@" HOME_LAB_SERVED_ADDR="127.0.0.1:$PORT" SERVED_CERT_HOST=dashboard.example.test bash scripts/served-cert-check.sh > "$T/o" 2>&1 || rc=$?
  check "$desc (exit $want)" test "$rc" -eq "$want"
}

next_port || {
  echo "no free local port for the test TLS server" >&2
  exit 2
}
mkcert good 90 dashboard.example.test
mkcert soon 10 dashboard.example.test
mkcert crit 3 dashboard.example.test
mkcert other 90 other.example.test
if serve good; then
  served 0 "90 days left"
  check "the PASS line names the host and the days left, no key material" bash -c 'grep -q "^\[PASS\] served-cert: dashboard.example.test certificate has 8[0-9] days left" "$1" && ! grep -qi "PRIVATE" "$1"' _ "$T/o"
  served 1 "20 days warn threshold: 90 days is fine, so raise it above 100 and the same certificate warns" SERVED_CERT_WARN_DAYS=100
  check "the WARN line is produced" grep -q '^\[WARN\] served-cert' "$T/o"
else bad "could not start the local TLS server (good)"; fi
if serve soon; then
  served 1 "10 days left is under the default 21-day threshold: WARN"
  served 0 "the threshold is configurable: 5 days accepts 10 days left" SERVED_CERT_WARN_DAYS=5
else bad "could not start the local TLS server (soon)"; fi
if serve crit; then
  served 2 "3 days left is under the 7-day critical threshold: FAIL"
else bad "could not start the local TLS server (crit)"; fi
if serve other; then
  served 2 "a certificate for another name (Traefik default certificate) is a FAIL"
  check "the FAIL line says the name is not covered" grep -q 'does not cover that name' "$T/o"
else bad "could not start the local TLS server (other)"; fi
kill "$SRV_PID" 2> /dev/null || true
SRV_PID=""
sleep 0.5
served 3 "nothing listening: no TLS certificate"
rc=0
SERVED_CERT_WARN_DAYS=abc HOME_LAB_SERVED_ADDR="127.0.0.1:$PORT" SERVED_CERT_HOST=x.example.test bash scripts/served-cert-check.sh > "$T/o" 2>&1 || rc=$?
check "a non-numeric threshold is refused" test "$rc" -ne 0

# ---------------------------------------------------------------- alert.sh with a mock aws
ETC="$T/etc"
STATE="$T/state"
mkdir -p "$ETC/pki" "$T/mockbin"
: > "$ETC/pki/host.crt"
: > "$ETC/pki/host.key"
write_env() { # write_env [with-topic]
  cat > "$ETC/aws.env" << ENV
AWS_REGION=af-south-1
RA_TRUST_ANCHOR_ARN=arn:aws:rolesanywhere:af-south-1:111111111111:trust-anchor/00000000-0000-0000-0000-000000000003
RA_HOST_PROFILE_ARN=arn:aws:rolesanywhere:af-south-1:111111111111:profile/00000000-0000-0000-0000-000000000004
RA_HOST_ROLE_ARN=arn:aws:iam::111111111111:role/home-lab-pi-host
ENV
  if [ "${1:-}" = with-topic ]; then
    echo "ALERT_TOPIC_ARN=arn:aws:sns:af-south-1:111111111111:home-lab-alerts" >> "$ETC/aws.env"
  fi
}
cat > "$T/mockbin/aws" << 'MOCK'
#!/usr/bin/env bash
# MOCK aws: records the call, checks the profile the script wrote, never touches a network.
if [ "$*" = "--mock-marker" ]; then echo MOCK-AWS-MARKER; exit 0; fi
{
  printf 'ARGS %s\n' "$*"
  printf 'PROFILE %s\n' "${AWS_PROFILE:-}"
  if grep -q '^credential_process = /usr/local/bin/aws_signing_helper credential-process' "${AWS_CONFIG_FILE:-/nonexistent}" 2> /dev/null; then echo "CONFIG-OK"; fi
  printf 'MODE %s\n' "$(stat -c %a "$(dirname "${AWS_CONFIG_FILE:-/nonexistent}")" 2> /dev/null || echo none)"
} >> "$MOCK_LOG"
[ -z "${MOCK_FAIL:-}" ] || { echo "An error occurred (AccessDenied) when calling the Publish operation: not allowed"; exit 254; }
echo "11111111-2222-3333-4444-555555555555"
MOCK
chmod +x "$T/mockbin/aws"
export MOCK_LOG="$T/mock.log"
export PATH="$T/mockbin:$PATH"
case "$(command -v aws)" in "$T"/mockbin/aws) ;; *)
  echo "ABORT: aws is not the mock" >&2
  exit 3
  ;;
esac
[ "$(aws --mock-marker)" = MOCK-AWS-MARKER ] || {
  echo "ABORT: mock marker failed" >&2
  exit 3
}
alert() { env HOME_LAB_ETC_DIR="$ETC" HOME_LAB_STATE_DIR="$STATE" "$@"; }
calls() { grep -c '^ARGS sns publish' "$MOCK_LOG" 2> /dev/null || true; }
: > "$MOCK_LOG"

rc=0
write_env
alert bash scripts/alert.sh test > "$T/o" 2>&1 || rc=$?
check "alert.sh test without a topic: fails with a clear message, no AWS call" bash -c 'test "$1" -ne 0 && grep -q "ALERT_TOPIC_ARN is missing" "$2" && test "$(grep -c "^ARGS" "$3" || true)" -eq 0' _ "$rc" "$T/o" "$MOCK_LOG"

write_env with-topic
rc=0
alert bash scripts/alert.sh test > "$T/o" 2>&1 || rc=$?
check "alert.sh test publishes to the topic with the host profile" bash -c 'test "$1" -eq 0 && grep -q "sns publish --topic-arn arn:aws:sns:af-south-1:111111111111:home-lab-alerts" "$2" && grep -q "^PROFILE home-lab-host" "$2" && grep -q "^CONFIG-OK" "$2"' _ "$rc" "$MOCK_LOG"
check "the temporary AWS profile directory was private (0700)" grep -q '^MODE 700' "$MOCK_LOG"
check "the output names the message id and no credential" bash -c 'grep -q "alert published" "$1" && ! grep -Eqi "secret|session|token|BEGIN" "$1"' _ "$T/o"
check "a test mail is not rate limited and leaves no state" bash -c 'alert() { env HOME_LAB_ETC_DIR="$1" HOME_LAB_STATE_DIR="$2" "${@:3}"; }; alert "$1" "$2" bash scripts/alert.sh test > /dev/null 2>&1 && test "$(grep -c "^ARGS sns publish" "$3")" -eq 2' _ "$ETC" "$STATE" "$MOCK_LOG"

: > "$MOCK_LOG"
rc=0
alert bash scripts/alert.sh send demo-key "subject one" "message one" > "$T/o" 2>&1 || rc=$?
check "send: first alert goes out" test "$rc" -eq 0 -a "$(calls)" -eq 1
alert bash scripts/alert.sh send demo-key "subject one" "message one" > "$T/o" 2>&1
check "send: the second alert for the same key within a day is suppressed" bash -c 'grep -q "suppressed" "$1"' _ "$T/o"
check "send: still exactly one publish" test "$(calls)" -eq 1
alert bash scripts/alert.sh send other-key "subject two" "message two" > "$T/o" 2>&1
check "send: a different key is not suppressed" test "$(calls)" -eq 2
echo 1 > "$STATE/alert-demo-key.last"
alert bash scripts/alert.sh send demo-key "subject one" "message one" > "$T/o" 2>&1
check "send: after the interval the same key alerts again" test "$(calls)" -eq 3
rc=0
alert bash scripts/alert.sh send 'Bad Key' s m > "$T/o" 2>&1 || rc=$?
check "send: a bad key is refused" test "$rc" -ne 0
rc=0
alert env MOCK_FAIL=1 bash scripts/alert.sh send fail-key s m > "$T/o" 2>&1 || rc=$?
check "send: a failed publish exits non-zero, shows one line of AWS text and writes no state" bash -c 'test "$1" -ne 0 && grep -q "publish failed" "$2" && ! test -e "$3/alert-fail-key.last"' _ "$rc" "$T/o" "$STATE"

# check: one bad certificate in a PKI dir, no Traefik (served-cert reports exit 3, treated as a failure)
mkdir -p "$T/pki"
for n in traefik host; do
  cp "$T/good.crt" "$T/pki/$n.crt"
done
rm -rf "$STATE"
: > "$MOCK_LOG"
rc=0
alert env HOME_LAB_PKI_DIR="$T/pki" HOME_LAB_SERVED_ADDR="127.0.0.1:$PORT" SERVED_CERT_HOST=dashboard.example.test bash scripts/alert.sh check > "$T/o" 2>&1 || rc=$?
check "check: healthy Pi certificates but nothing served: exit 2 and one served-cert alert only" bash -c 'test "$1" -eq 2 && grep -q "^\[PASS\] host.crt" "$2" && grep -q "^\[FAIL\] served-cert" "$2" && test "$(grep -c "^ARGS sns publish" "$3")" -eq 1 && grep -q "served by Traefik" "$3"' _ "$rc" "$T/o" "$MOCK_LOG"
rc=0
alert env HOME_LAB_PKI_DIR="$T/pki" HOME_LAB_SERVED_ADDR="127.0.0.1:$PORT" SERVED_CERT_HOST=dashboard.example.test bash scripts/alert.sh check > "$T/o" 2>&1 || rc=$?
check "check: the same failure the same day does not mail again" test "$(calls)" -eq 1
rm -f "$T/pki/host.crt"
rc=0
alert env HOME_LAB_PKI_DIR="$T/pki" HOME_LAB_SERVED_ADDR="127.0.0.1:$PORT" SERVED_CERT_HOST=dashboard.example.test bash scripts/alert.sh check > "$T/o" 2>&1 || rc=$?
check "check: a missing Roles Anywhere certificate alerts too (its own key, so a second mail)" test "$(calls)" -eq 2
check "check: the Roles Anywhere alert subject names the check" grep -q 'Roles Anywhere certificates' "$MOCK_LOG"

# unit-failed: skipped right after a check alert, sent otherwise
rc=0
alert bash scripts/alert.sh unit-failed home-lab-cert-expiry.service > "$T/o" 2>&1 || rc=$?
check "unit-failed right after a check alert: no second mail" bash -c 'test "$1" -eq 0 && grep -q "no second mail" "$2"' _ "$rc" "$T/o"
rm -f "$STATE/.check-alerted"
: > "$MOCK_LOG"
alert bash scripts/alert.sh unit-failed home-lab-cert-expiry.service > "$T/o" 2>&1
check "unit-failed with no check alert: mails once" test "$(calls)" -eq 1
alert bash scripts/alert.sh unit-failed home-lab-cert-expiry.service > "$T/o" 2>&1
check "unit-failed is rate limited too" test "$(calls)" -eq 1
rc=0
alert bash scripts/alert.sh unit-failed 'bad unit;rm' > "$T/o" 2>&1 || rc=$?
check "unit-failed refuses a malformed unit name" test "$rc" -ne 0
rc=0
alert bash scripts/alert.sh bogus > "$T/o" 2>&1 || rc=$?
check "an unknown command exits 2" test "$rc" -eq 2

# ---------------------------------------------------------------- wiring
check "the service runs alert.sh check and fails over to the OnFailure handler" bash -c 'grep -q "^ExecStart=.*scripts/alert.sh check" scripts/systemd/home-lab-cert-expiry.service && grep -q "^OnFailure=home-lab-alert-failure@%n.service" scripts/systemd/home-lab-cert-expiry.service && grep -q "alert.sh unit-failed %i" scripts/systemd/home-lab-alert-failure@.service'
check "the service may write its state (StateDirectory) under ProtectSystem=strict" bash -c 'grep -q "^StateDirectory=home-lab" scripts/systemd/home-lab-cert-expiry.service && grep -q "^ProtectSystem=strict" scripts/systemd/home-lab-cert-expiry.service'
check "bootstrap.sh installs the OnFailure template unit" grep -q 'home-lab-alert-failure@.service' scripts/bootstrap.sh
check "no credential or key value is ever echoed by the alert library" bash -c '! grep -nE "echo .*(SECRET|TOKEN|key)|printf .*\$\{?(secret|token)" scripts/lib/alert.sh scripts/alert.sh'

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll alert checks passed\n'
