#!/usr/bin/env bash
# test-alert.sh - offline self-test of the K4 alert path: scripts/served-cert-check.sh, scripts/alert.sh, scripts/lib/alert.sh,
# scripts/lib/units.sh and the systemd unit files. Needs openssl (with `openssl ca`), flock and bash. No root, no AWS, no network beyond 127.0.0.1:
#   - served-cert-check.sh against a local `openssl s_server`: healthy, WARN, FAIL, expired, not valid yet, wrong name, staging issuer
#     behind a production config, untrusted chain, staging config, nothing listening, a broken setting (exit 4)
#   - alert.sh with a MOCK aws that records its arguments: test, rate limit with slack, per-state keys (escalation mails), corrupt, future
#     and leading-zero state files, concurrent sends, down grace and boot grace, "check could not run", unit-failed per unit
#   - unit drift detection and the hardening of the unit files
# The mock aws is placed first on PATH, real credentials and config are disabled, and the mock is PROVED before use.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"
for t in openssl flock; do
  command -v "$t" > /dev/null || {
    echo "$t is required" >&2
    exit 2
  }
done
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

# ---------------------------------------------------------------- certificates
# mkcert <name> <start> <end> <dns name> [issuer name]: certificate with a SAN and an explicit validity (openssl ca). Without an issuer
# name it is self-signed; with one, <name>.crt is signed by a CA called that (the CA files are $T/ca-<issuer>.{crt,key}).
mkcert() {
  local name="$1" start="$2" end="$3" dns="$4" issuer="${5:-}" d="$T/ca-$1"
  mkdir -p "$d"
  : > "$d/index"
  echo 01 > "$d/serial"
  cat > "$d/cnf" << CNF
[req]
distinguished_name=dn
prompt=no
[dn]
CN=$dns
[ca]
default_ca=cad
[cad]
dir=$d
database=$d/index
new_certs_dir=$d
serial=$d/serial
default_md=sha256
policy=pol
unique_subject=no
copy_extensions=none
x509_extensions=ext
[pol]
commonName=supplied
[ext]
subjectAltName=DNS:$dns
CNF
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/$name.key" -out "$d/req.csr" -config "$d/cnf" 2> /dev/null
  if [ -z "$issuer" ]; then
    openssl ca -batch -selfsign -keyfile "$T/$name.key" -in "$d/req.csr" -out "$T/$name.crt" -notext -startdate "$start" -enddate "$end" -config "$d/cnf" 2> /dev/null
  else
    mkca "$issuer"
    openssl ca -batch -keyfile "$T/ca-$issuer.key" -cert "$T/ca-$issuer.crt" -in "$d/req.csr" -out "$T/$name.crt" -notext -startdate "$start" -enddate "$end" -config "$d/cnf" 2> /dev/null
  fi
}
mkca() { # mkca <name>: a CA certificate whose common name is <name> (once)
  [ -f "$T/ca-$1.crt" ] && return 0
  printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=v3\n[dn]\nCN=%s\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=keyCertSign,cRLSign\n' "$1" > "$T/ca-$1.cnf"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/ca-$1.key" -out "$T/ca-$1.crt" -days 3650 -config "$T/ca-$1.cnf" 2> /dev/null
}
now_plus() { date -u -d "$1" +%Y%m%d%H%M%SZ; }
TODAY="$(now_plus 'now - 1 day')"
mkcert good "$TODAY" "$(now_plus 'now + 90 days')" dashboard.example.test
mkcert soon "$TODAY" "$(now_plus 'now + 10 days')" dashboard.example.test
mkcert crit "$TODAY" "$(now_plus 'now + 3 days')" dashboard.example.test
mkcert other "$TODAY" "$(now_plus 'now + 90 days')" other.example.test
mkcert expired 20200101000000Z 20200102000000Z dashboard.example.test
mkcert future 20990101000000Z 21000101000000Z dashboard.example.test
mkcert prodleaf "$TODAY" "$(now_plus 'now + 90 days')" dashboard.example.test "Test Root X1"
mkcert stgleaf "$TODAY" "$(now_plus 'now + 90 days')" dashboard.example.test "(STAGING) Test Root X1"

NEXT_PORT=18443
next_port() { # set PORT to a local port nobody listens on, never reusing one (a killed server may linger on Windows)
  while [ "$NEXT_PORT" -lt 18900 ]; do
    PORT="$NEXT_PORT"
    NEXT_PORT=$((NEXT_PORT + 1))
    (exec 3<> "/dev/tcp/127.0.0.1/$PORT") 2> /dev/null || return 0
  done
  return 1
}
serve() { # serve <name>: s_server for that certificate on a fresh port ($PORT) until stopped
  [ -z "$SRV_PID" ] || kill "$SRV_PID" 2> /dev/null || true
  next_port || return 1
  openssl s_server -quiet -accept "$PORT" -cert "$T/$1.crt" -key "$T/$1.key" > /dev/null 2>&1 &
  SRV_PID=$!
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    (exec 3<> "/dev/tcp/127.0.0.1/$PORT") 2> /dev/null && return 0
    sleep 0.3
  done
  return 1
}
# served <expected exit code> <description> [env assignments...]: default expectation "any" (the cases below set it when it matters)
served() {
  local want="$1" desc="$2" rc=0
  shift 2
  env SERVED_CERT_EXPECT=any "$@" HOME_LAB_SERVED_ADDR="127.0.0.1:$PORT" SERVED_CERT_HOST=dashboard.example.test bash scripts/served-cert-check.sh > "$T/o" 2>&1 || rc=$?
  check "$desc (exit $want)" test "$rc" -eq "$want"
}
CA_PROD="SERVED_CERT_CAFILE=$T/ca-Test Root X1.crt"

# ---------------------------------------------------------------- served-cert-check.sh
if serve good; then
  served 0 "90 days left"
  check "the PASS line names the host and the days left, no key material" bash -c 'grep -q "^\[PASS\] served-cert: dashboard.example.test certificate has 8[0-9] days left" "$1" && ! grep -qi "PRIVATE" "$1"' _ "$T/o"
  served 1 "a threshold above the days left warns" SERVED_CERT_WARN_DAYS=100
  check "the WARN line is produced" grep -q '^\[WARN\] served-cert' "$T/o"
  served 2 "production expected but a self-signed certificate is served (no chain to a trusted root)" SERVED_CERT_EXPECT=prod
  check "...and the message says it does not chain" grep -q 'does not chain' "$T/o"
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
if serve expired; then
  served 2 "an expired certificate is a FAIL (QA-L-9)"
  check "...and says EXPIRED" grep -q 'EXPIRED' "$T/o"
else bad "could not start the local TLS server (expired)"; fi
if serve future; then
  served 2 "a certificate that is not valid yet is a FAIL, not a PASS (QA-L-4)"
  check "...and names the clock" bash -c 'grep -q "NOT VALID YET" "$1" && grep -qi clock "$1"' _ "$T/o"
else bad "could not start the local TLS server (future)"; fi
if serve prodleaf; then
  served 0 "production expected, a certificate that chains to the trusted root: PASS" SERVED_CERT_EXPECT=prod "$CA_PROD"
  check "...and the PASS line shows the issuer" grep -q 'CN=Test Root X1' "$T/o"
  served 2 "production expected, the same certificate but an unknown root (no trust store): FAIL" SERVED_CERT_EXPECT=prod "SERVED_CERT_CAFILE=$T/ca-(STAGING) Test Root X1.crt"
  served 1 "staging expected, but a non-staging issuer is served: WARN (QA-M-1)" SERVED_CERT_EXPECT=staging
else bad "could not start the local TLS server (prodleaf)"; fi
if serve stgleaf; then
  served 2 "production expected, a STAGING issuer is served: FAIL (QA-M-1, SEC-L-5)" SERVED_CERT_EXPECT=prod
  check "...and says staging, with the runbook step" grep -q 'STAGING certificate' "$T/o"
  served 0 "staging expected and a staging issuer is served: PASS" SERVED_CERT_EXPECT=staging
else bad "could not start the local TLS server (stgleaf)"; fi
kill "$SRV_PID" 2> /dev/null || true
SRV_PID=""
sleep 0.5
served 3 "nothing listening: no TLS certificate"
served 4 "a non-numeric threshold: the check could not run" SERVED_CERT_WARN_DAYS=abc
check "...and says so (a problem with the check, not with the certificate)" grep -q 'the check could not run' "$T/o"
served 4 "a bad SERVED_CERT_EXPECT value" SERVED_CERT_EXPECT=bogus
rc=0
HOME_LAB_SERVED_ADDR="127.0.0.1:$PORT" SERVED_CERT_HOST='a b' bash scripts/served-cert-check.sh > "$T/o" 2>&1 || rc=$?
check "a host name with a space is refused (exit 4)" test "$rc" -eq 4
# the repository's own config/lab.env asks for the staging CA: with no override the expectation comes from it
check "with no override the expectation comes from ACME_CA_SERVER in config/lab.env" bash -c 'grep -q "ACME_CA_SERVER" scripts/served-cert-check.sh && grep -q "acme-v02" scripts/served-cert-check.sh && grep -q "acme-staging-v02" scripts/served-cert-check.sh'

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
[ -z "${MOCK_SLEEP:-}" ] || sleep "$MOCK_SLEEP"
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
# alert <env assignments and command...>: HOME_LAB_BOOT_GRACE=0 (the test host has been up for a while anyway) and a fake uptime file
echo "99999.00 1.00" > "$T/uptime"
alert() { env HOME_LAB_ETC_DIR="$ETC" HOME_LAB_STATE_DIR="$STATE" HOME_LAB_UPTIME_FILE="$T/uptime" "$@"; }
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
check "the subject and message are passed as --option=value with fixed leading text (SEC-L-7)" bash -c 'grep -q -- "--subject=home-lab TEST alert --message=home-lab alert" "$1"' _ "$MOCK_LOG"
check "the temporary AWS profile directory was private (0700)" grep -q '^MODE 700' "$MOCK_LOG"
check "the output names the message id and no credential" bash -c 'grep -q "alert published" "$1" && ! grep -Eqi "secret|session|token|BEGIN" "$1"' _ "$T/o"
check "a successful test leaves the heartbeat file preflight looks at" test -s "$STATE/alert-test.published"
check "the test mail names the monthly heartbeat" grep -q 'monthly' "$MOCK_LOG"
alert bash scripts/alert.sh test > /dev/null 2>&1
check "a test mail is not rate limited" test "$(calls)" -eq 2

: > "$MOCK_LOG"
alert bash scripts/alert.sh send demo-key "subject one" "message one" > "$T/o" 2>&1
check "send: first alert goes out" test "$(calls)" -eq 1
alert bash scripts/alert.sh send demo-key "subject one" "message one" > "$T/o" 2>&1
check "send: the second alert for the same key within a day is suppressed" bash -c 'grep -q "suppressed" "$1"' _ "$T/o"
check "send: still exactly one publish" test "$(calls)" -eq 1
alert bash scripts/alert.sh send other-key "subject two" "message two" > "$T/o" 2>&1
check "send: a different key is not suppressed" test "$(calls)" -eq 2
echo $(($(date +%s) - 23 * 3600)) > "$STATE/alert-demo-key.last"
alert bash scripts/alert.sh send demo-key "subject one" "message one" > "$T/o" 2>&1
check "send: 23 hours later it alerts again (slack for the timer's random delay, QA-L-1)" test "$(calls)" -eq 3
echo $(($(date +%s) - 3600)) > "$STATE/alert-demo-key.last"
alert bash scripts/alert.sh send demo-key "subject one" "message one" > "$T/o" 2>&1
check "send: after 1 hour it is still suppressed" test "$(calls)" -eq 3
echo 1 > "$STATE/alert-demo-key.last"
alert bash scripts/alert.sh send demo-key "-x --topic-arn evil" "file:///etc/passwd" > /dev/null 2>&1
check "send: a subject starting with a dash and a file:// message are neutralised (SEC-L-7)" bash -c 'grep -q -- "--subject=home-lab: -x --topic-arn evil --message=home-lab alert" "$1" && ! grep -q -- "--message=file://" "$1"' _ "$MOCK_LOG"
rc=0
alert bash scripts/alert.sh send 'Bad Key' s m > "$T/o" 2>&1 || rc=$?
check "send: a bad key is refused" test "$rc" -ne 0
rc=0
alert env MOCK_FAIL=1 bash scripts/alert.sh send fail-key s m > "$T/o" 2>&1 || rc=$?
check "send: a failed publish exits non-zero, shows one line of AWS text and writes no state" bash -c 'test "$1" -ne 0 && grep -q "publish failed" "$2" && ! test -e "$3/alert-fail-key.last"' _ "$rc" "$T/o" "$STATE"

# corrupt, future and leading-zero state files must never silence an alert (QA-M-2, QA-L-6)
for bad in "$(($(date +%s) + 315360000))" 99999999999999999999 08 -5 abc "" "0x10"; do
  : > "$MOCK_LOG"
  printf '%s\n' "$bad" > "$STATE/alert-st.last"
  rc=0
  alert bash scripts/alert.sh send st s m > "$T/o" 2>&1 || rc=$?
  check "send: state '${bad:-empty}' is treated as stale, the alert goes out" bash -c 'test "$1" -eq 0 && test "$(grep -c "^ARGS sns publish" "$2")" -eq 1' _ "$rc" "$MOCK_LOG"
done
# the state written is a plain epoch that is then honoured
: > "$MOCK_LOG"
alert bash scripts/alert.sh send st s m > /dev/null 2>&1
check "send: the rewritten state suppresses the next one" test "$(calls)" -eq 0

# concurrency: two parallel sends for one key publish once (QA-L-7)
rm -f "$STATE/alert-race.last"
: > "$MOCK_LOG"
(alert env MOCK_SLEEP=1 bash scripts/alert.sh send race s m > /dev/null 2>&1 &
  alert env MOCK_SLEEP=1 bash scripts/alert.sh send race s m > /dev/null 2>&1 &
  wait)
check "send: two parallel sends for one key publish exactly once" test "$(calls)" -eq 1

# check: Pi certificates fine, nothing served (the first sighting is only recorded: a planned stop must not mail, QA-L-5)
mkdir -p "$T/pki"
for n in traefik host; do
  cp "$T/good.crt" "$T/pki/$n.crt"
done
rm -rf "$STATE"
: > "$MOCK_LOG"
chk() { alert env HOME_LAB_PKI_DIR="$T/pki" HOME_LAB_SERVED_ADDR="127.0.0.1:$PORT" SERVED_CERT_HOST=dashboard.example.test SERVED_CERT_EXPECT=any "$@" bash scripts/alert.sh check > "$T/o" 2>&1; }
rc=0
chk HOME_LAB_DOWN_GRACE=3600 || rc=$?
check "check: nothing served, first sighting: recorded, exit 0, NO mail" bash -c 'test "$1" -eq 0 && grep -q "^\[PASS\] host.crt" "$2" && grep -q "recorded" "$2" && test "$(grep -c "^ARGS sns publish" "$3")" -eq 0' _ "$rc" "$T/o" "$MOCK_LOG"
rc=0
chk HOME_LAB_DOWN_GRACE=3600 || rc=$?
check "check: second sighting inside the grace period: still no mail" test "$(calls)" -eq 0
rc=0
chk HOME_LAB_DOWN_GRACE=0 || rc=$?
check "check: still down after the grace period: exit 2 and one CRITICAL mail for the served certificate" bash -c 'test "$1" -eq 2 && grep -q "^\[FAIL\] served-cert" "$2" && test "$(grep -c "^ARGS sns publish" "$3")" -eq 1 && grep -q "served by Traefik" "$3" && grep -q "CRITICAL" "$3"' _ "$rc" "$T/o" "$MOCK_LOG"
chk HOME_LAB_DOWN_GRACE=0 || true
check "check: the same state the same day does not mail again" test "$(calls)" -eq 1
echo "30.00 1.00" > "$T/uptime"
rm -f "$STATE"/alert-served-cert-down.last "$STATE"/.down-served-cert
: > "$MOCK_LOG"
chk HOME_LAB_DOWN_GRACE=0 || true
check "check: a Pi that booted 30 seconds ago does not mail about a service that is not up yet (boot grace)" test "$(calls)" -eq 0
echo "99999.00 1.00" > "$T/uptime"

# escalation inside one day mails again: WARN (10 days left), then CRITICAL (a wrong certificate)
rm -rf "$STATE"
: > "$MOCK_LOG"
serve soon || bad "no TLS server (soon)"
chk || true
check "check: a WARN is mailed (state warn)" bash -c 'test "$(grep -c "^ARGS sns publish" "$1")" -eq 1 && grep -q "WARNING" "$1"' _ "$MOCK_LOG"
serve other || bad "no TLS server (other)"
chk || true
check "check: the escalation to FAIL a little later is mailed too, not suppressed (QA-L-3)" bash -c 'test "$(grep -c "^ARGS sns publish" "$1")" -eq 2 && grep -q "CRITICAL" "$1"' _ "$MOCK_LOG"
kill "$SRV_PID" 2> /dev/null || true
SRV_PID=""

# a check that crashes is not a certificate warning (QA-L-2)
rm -rf "$STATE"
: > "$MOCK_LOG"
rc=0
chk SERVED_CERT_WARN_DAYS=abc || rc=$?
check "check: a broken check setting mails 'could not run', not a certificate warning" bash -c 'grep -q "the check could not run" "$1" && grep -q "CRITICAL" "$1"' _ "$MOCK_LOG"

# Roles Anywhere certificates: a missing one alerts under its own key
rm -rf "$STATE"
: > "$MOCK_LOG"
rm -f "$T/pki/host.crt"
chk HOME_LAB_DOWN_GRACE=0 || true
check "check: a missing Roles Anywhere certificate alerts (subject names the check)" grep -q 'Roles Anywhere certificates' "$MOCK_LOG"

# unit-failed: skipped right after a check alert for THAT unit only, sent otherwise
mkdir -p "$STATE"
check "check wrote a per-unit marker (not a global one, QA-L-8)" bash -c 'ls -A "$1" | grep -q "^.check-alerted-"' _ "$STATE"
rc=0
alert bash scripts/alert.sh unit-failed home-lab-cert-expiry.service > "$T/o" 2>&1 || rc=$?
check "unit-failed for the checking unit right after its alert: no second mail" bash -c 'test "$1" -eq 0 && grep -q "no second mail" "$2"' _ "$rc" "$T/o"
: > "$MOCK_LOG"
alert bash scripts/alert.sh unit-failed docker.service > "$T/o" 2>&1
check "unit-failed for ANOTHER unit within 10 minutes still mails (the marker is per unit)" test "$(calls)" -eq 1
alert bash scripts/alert.sh unit-failed docker.service > "$T/o" 2>&1
check "unit-failed is rate limited per unit" test "$(calls)" -eq 1
alert bash scripts/alert.sh unit-failed 'a-very-long-unit-name-with-a-shared-prefix-1.service' > /dev/null 2>&1
alert bash scripts/alert.sh unit-failed 'a-very-long-unit-name-with-a-shared-prefix-2.service' > /dev/null 2>&1
check "units sharing a long prefix get separate budgets (hashed key, SEC-L-6)" test "$(calls)" -eq 3
alert bash scripts/alert.sh unit-failed 'systemd-escaped\x2dname.service' > /dev/null 2>&1
check "an escaped unit name is accepted" test "$(calls)" -eq 4
rc=0
alert bash scripts/alert.sh unit-failed 'bad unit;rm' > "$T/o" 2>&1 || rc=$?
check "a malformed unit name still sends a generic alert instead of dying (SEC-L-6)" bash -c 'test "$1" -eq 0 && test "$(grep -c "^ARGS sns publish" "$2")" -eq 5 && grep -q "a unit failed" "$2"' _ "$rc" "$MOCK_LOG"
rc=0
alert bash scripts/alert.sh bogus > "$T/o" 2>&1 || rc=$?
check "an unknown command exits 2" test "$rc" -eq 2

# ---------------------------------------------------------------- units: installation, drift, hardening
SD="$T/systemd"
mkdir -p "$SD"
# shellcheck source=lib/common.sh
. scripts/lib/common.sh
# shellcheck source=lib/units.sh
HOME_LAB_SYSTEMD_DIR="$SD" . scripts/lib/units.sh
install_all() { for u in "${LAB_UNITS[@]}"; do render_unit "$REPO" /apps "$u" > "$SD/$u"; done; }
install_all
check "drift: freshly rendered units are current (no output)" test -z "$(unit_drift "$REPO" /apps)"
check "rendered units have no @placeholders left" bash -c '! grep -h "@REPO_DIR@\|@APPS_ROOT@" "$1"/*' _ "$SD"
printf '# edited\n' >> "$SD/home-lab-cert-expiry.service"
d="$(unit_drift "$REPO" /apps)"
check "drift: an installed unit that differs from the repository copy is reported, naming the unit (QA-M-3)" bash -c 'echo "$1" | grep -q "home-lab-cert-expiry.service: differs"' _ "$d"
rm -f "$SD/home-lab-alert-failure@.service"
d="$(unit_drift "$REPO" /apps)"
check "drift: a unit that was never installed is reported" bash -c 'echo "$1" | grep -q "home-lab-alert-failure@.service: not installed"' _ "$d"
check "bootstrap.sh installs from the same unit list the drift check uses" bash -c 'grep -q "LAB_UNITS" scripts/bootstrap.sh && grep -q "unit_drift" scripts/preflight.sh && grep -q "unit_drift" scripts/deploy.sh'
check "preflight fails (not warns) on a stale unit" bash -c 'grep -q "fail systemd-units" scripts/preflight.sh'

for u in home-lab-cert-expiry.service home-lab-alert-failure@.service home-lab-alert-test.service; do
  check "$u is hardened (NoNewPrivileges, PrivateTmp, ProtectHome, strict fs, devices, kernel, address families, syscalls)" bash -c 'f="scripts/systemd/$1"; for k in NoNewPrivileges=true PrivateTmp=true ProtectHome=true ProtectSystem=strict PrivateDevices=true ProtectKernelTunables=true ProtectControlGroups=true "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" RestrictNamespaces=true LockPersonality=true "SystemCallFilter=@system-service" StateDirectory=home-lab; do grep -qx "$k" "$f" || { echo "missing $k in $1"; exit 1; }; done' _ "$u"
done
check "the service runs alert.sh check and fails over to the OnFailure handler" bash -c 'grep -q "^ExecStart=.*scripts/alert.sh check" scripts/systemd/home-lab-cert-expiry.service && grep -q "^OnFailure=home-lab-alert-failure@%n.service" scripts/systemd/home-lab-cert-expiry.service && grep -q "alert.sh unit-failed %i" scripts/systemd/home-lab-alert-failure@.service'
check "the monthly heartbeat: a timer runs alert.sh test (SEC-M-2) and bootstrap enables it" bash -c 'grep -q "^OnCalendar=monthly" scripts/systemd/home-lab-alert-test.timer && grep -q "^ExecStart=.*scripts/alert.sh test" scripts/systemd/home-lab-alert-test.service && grep -q "home-lab-alert-test.timer" scripts/bootstrap.sh'
check "no credential or key value is ever echoed by the alert library" bash -c '! grep -nE "echo .*(SECRET|TOKEN|key)|printf .*\$\{?(secret|token)" scripts/lib/alert.sh scripts/alert.sh'

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll alert checks passed\n'
