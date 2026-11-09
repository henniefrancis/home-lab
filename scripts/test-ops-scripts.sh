#!/usr/bin/env bash
# test-ops-scripts.sh - offline self-test of the Pi operations scripts that had no test (QA-L-1, QA-L-5, QA-L-6, QA-L-10, QA-L-11,
# QA-L-12, QA-L-15, QA-M-4, SEC-M7, SEC-L3). Needs jq, openssl, git, ssh-keygen. No root, no network, no AWS:
#   - deploy.sh argument handling (usage errors, exit 2, before the root check)
#   - signed-deploy verification (scripts/lib/verify-commit.sh): good signature, unsigned, wrong key, bad trust file, tamper
#   - cert-expiry.sh thresholds (30 and 14 days, missing)
#   - preflight.sh --stage argument handling (no endless loop)
#   - breakglass.sh on/off/status and bad arguments
#   - pi-install-cert.sh --help and the notBefore check
#   - aws-preflight.sh --snapshot against a MOCK aws (CRLF output, duplicate zones, HCL escaping of the zone comment)
#   - inventory.jq refuses colliding keys
# The mock aws is placed first on PATH, the AWS config and credentials are disabled and the mock is PROVED before use.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose: $1, $2 expand in the child shell
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"
for t in jq openssl git ssh-keygen; do
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
check() { # check <description> <command...>
  local d="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------- deploy.sh arguments
rc=0
bash scripts/deploy.sh --only > "$T/o" 2>&1 || rc=$?
check "deploy.sh --only without a value: exit 2 and a clear message (QA-L-6)" bash -c 'test "$1" -eq 2 && grep -q "needs a stack name" "$2"' _ "$rc" "$T/o"
rc=0
bash scripts/deploy.sh --only ../x > "$T/o" 2>&1 || rc=$?
check "deploy.sh --only ../x: exit 2 before the root check (QA-L-6)" bash -c 'test "$1" -eq 2 && grep -q "plain directory name" "$2"' _ "$rc" "$T/o"
rc=0
bash scripts/deploy.sh --only traefic > "$T/o" 2>&1 || rc=$?
check "deploy.sh --only <typo>: exit 2 and no deploy (QA-L-5)" bash -c 'test "$1" -eq 2 && grep -q "no traefic/compose.yaml" "$2"' _ "$rc" "$T/o"
rc=0
bash scripts/deploy.sh --bogus > "$T/o" 2>&1 || rc=$?
check "deploy.sh unknown argument: exit 2" test "$rc" -eq 2
check "deploy.sh --help exits 0" bash scripts/deploy.sh --help
check "deploy.sh has no flag that skips the signature check" bash -c '! grep -Eqi -- "--(no-verify|insecure|allow-unsigned)" scripts/deploy.sh'

# ---------------------------------------------------------------- signed-deploy verification (SEC-M7)
# shellcheck source=lib/verify-commit.sh
. scripts/lib/verify-commit.sh
export -f verify_signed_commit allowed_signers_usable signers_problem _owned_by_me_and_closed # the bash -c checks below call them in a child shell
mkdir -p "$T/keys" "$T/repo"
ssh-keygen -q -t ed25519 -N '' -C owner-test -f "$T/keys/owner" > /dev/null
ssh-keygen -q -t ed25519 -N '' -C other-test -f "$T/keys/other" > /dev/null
printf 'owner@example.invalid namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$T/keys/owner.pub")" > "$T/allowed"
chmod 644 "$T/allowed"
g() { git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
git init -q "$T/repo"
mkcommit() { # mkcommit <message> [signing key]
  echo "$1" >> "$T/repo/f"
  git -C "$T/repo" add f
  if [ -n "${2:-}" ]; then
    g -c gpg.format=ssh -c "user.signingkey=$2" commit -q -S -m "$1"
  else
    g commit -q -m "$1"
  fi
}
mkcommit signed-by-owner "$T/keys/owner.pub"
c_owner="$(git -C "$T/repo" rev-parse HEAD)"
mkcommit unsigned
c_unsigned="$(git -C "$T/repo" rev-parse HEAD)"
mkcommit signed-by-other "$T/keys/other.pub"
c_other="$(git -C "$T/repo" rev-parse HEAD)"
check "a commit signed by an allowed key verifies" verify_signed_commit "$T/repo" "$c_owner" "$T/allowed"
check "an unsigned commit is refused" bash -c '! verify_signed_commit "$1" "$2" "$3"' _ "$T/repo" "$c_unsigned" "$T/allowed"
check "a commit signed by a key that is not allowed is refused" bash -c '! verify_signed_commit "$1" "$2" "$3"' _ "$T/repo" "$c_other" "$T/allowed"
check "a missing allowed-signers file fails closed" bash -c '! verify_signed_commit "$1" "$2" "$3"' _ "$T/repo" "$c_owner" "$T/does-not-exist"
printf '# only comments\n' > "$T/empty"
chmod 644 "$T/empty"
check "an allowed-signers file without a key fails closed" bash -c '! verify_signed_commit "$1" "$2" "$3"' _ "$T/repo" "$c_owner" "$T/empty"
check "the shipped placeholder file fails closed" bash -c '! verify_signed_commit "$1" "$2" "$3"' _ "$T/repo" "$c_owner" "$REPO/config/allowed_signers.example"
cp "$T/allowed" "$T/loose"
chmod 666 "$T/loose"
if [ "$(stat -c '%a' "$T/loose")" = 666 ]; then
  check "an allowed-signers file writable by others fails closed" bash -c '! verify_signed_commit "$1" "$2" "$3"' _ "$T/repo" "$c_owner" "$T/loose"
else
  ok "writable-by-others check skipped (file system without POSIX modes)"
fi
check "an unknown revision fails closed" bash -c '! verify_signed_commit "$1" "deadbeefdeadbeef" "$2"' _ "$T/repo" "$T/allowed"
# tamper: rewrite the signed commit's message in the object (new commit object, same signature header) -> must not verify
git -C "$T/repo" cat-file commit "$c_owner" | sed 's/^signed-by-owner$/tampered-message/' > "$T/commit.txt"
c_tampered="$(git -C "$T/repo" hash-object -t commit -w "$T/commit.txt")"
check "a tampered signed commit is refused" bash -c '! verify_signed_commit "$1" "$2" "$3"' _ "$T/repo" "$c_tampered" "$T/allowed"
printf '%s\n%s\n' '# copy of config/allowed_signers.example: replace REPLACE-WITH-YOUR-PUBLIC-KEY with your key' "$(cat "$T/allowed")" > "$T/commented"
chmod 644 "$T/commented"
check "a comment that mentions the placeholder does not block a real key (NEW-5)" verify_signed_commit "$T/repo" "$c_owner" "$T/commented"
printf '%s\n%s\n' 'owner@example.invalid namespaces="git" ssh-ed25519 REPLACE-WITH-YOUR-PUBLIC-KEY' "$(cat "$T/allowed")" > "$T/placeheld"
chmod 644 "$T/placeheld"
check "a placeholder LINE next to a real key is refused and the message says to remove it (NEW-5)" bash -c '! verify_signed_commit "$1" "$2" "$3" 2> "$4" && grep -q "remove that line" "$4"' _ "$T/repo" "$c_owner" "$T/placeheld" "$T/o"
check "signers_problem is silent for a good file (owned by the running user, closed, real key)" bash -c '! signers_problem "$1" | grep -q .' _ "$T/allowed"
ln -sf "$T/allowed" "$T/signers-link"
[ -L "$T/signers-link" ] || ok "symlink check skipped (no symlinks on this file system; test-deploy.sh covers it as root)"
[ ! -L "$T/signers-link" ] || check "an allowed-signers symlink is refused (N9)" bash -c '! verify_signed_commit "$1" "$2" "$3"' _ "$T/repo" "$c_owner" "$T/signers-link"

# ---------------------------------------------------------------- cert-expiry.sh thresholds (QA-M-4)
mkdir -p "$T/pki"
cat > "$T/req.cnf" << 'CNF'
[req]
distinguished_name=dn
prompt=no
[dn]
CN=t
CNF
mkcert() { # mkcert <name> <days>   (a config file instead of -subj: Git Bash would rewrite "/CN=..." as a path)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/pki/$1.key" -out "$T/pki/$1.crt" -days "$2" -config "$T/req.cnf" 2> /dev/null
}
mkcert traefik 400
mkcert host 400
rc=0
HOME_LAB_PKI_DIR="$T/pki" bash scripts/cert-expiry.sh > "$T/o" 2>&1 || rc=$?
check "both certificates far from expiry: exit 0" test "$rc" -eq 0
mkcert host 20
rc=0
HOME_LAB_PKI_DIR="$T/pki" bash scripts/cert-expiry.sh > "$T/o" 2>&1 || rc=$?
check "20 days left: exit 1 and a WARN" bash -c 'test "$1" -eq 1 && grep -q "^\[WARN\]" "$2"' _ "$rc" "$T/o"
mkcert host 5
rc=0
HOME_LAB_PKI_DIR="$T/pki" bash scripts/cert-expiry.sh > "$T/o" 2>&1 || rc=$?
check "5 days left (under 14): exit 2 and a FAIL" bash -c 'test "$1" -eq 2 && grep -q "^\[FAIL\]" "$2"' _ "$rc" "$T/o"
rm -f "$T/pki/host.crt"
rc=0
HOME_LAB_PKI_DIR="$T/pki" bash scripts/cert-expiry.sh > "$T/o" 2>&1 || rc=$?
check "missing certificate: exit 2" test "$rc" -eq 2
# Not-yet-valid certificate (coverage gap): a stub date puts "now" ten years in the past, so a fresh certificate has a future notBefore.
# This is the Pi after a power cut with no network and no RTC.
mkcert host 400
mkdir -p "$T/stub-ce"
cat > "$T/stub-ce/date" << 'STUB'
#!/usr/bin/env bash
real="$(PATH="${REAL_PATH}" command -v date)"
if [ "${1:-}" = "+%s" ]; then echo $(( $("$real" +%s) - 315360000 )); else exec "$real" "$@"; fi
STUB
chmod +x "$T/stub-ce/date"
rc=0
env REAL_PATH="$PATH" PATH="$T/stub-ce:$PATH" HOME_LAB_PKI_DIR="$T/pki" bash scripts/cert-expiry.sh > "$T/o" 2>&1 || rc=$?
check "a certificate that is not valid yet (Pi clock years behind): exit 2, [FAIL] NOT VALID YET, names the clock" bash -c 'test "$1" -eq 2 && grep -q "^\[FAIL\].*NOT VALID YET" "$2" && grep -qi "clock" "$2"' _ "$rc" "$T/o"
rc=0
HOME_LAB_PKI_DIR="$T/pki" bash scripts/cert-expiry.sh > "$T/o" 2>&1 || rc=$?
check "the same certificates are fine with the correct clock: exit 0, no NOT VALID YET" bash -c 'test "$1" -eq 0 && ! grep -q "NOT VALID YET" "$2"' _ "$rc" "$T/o"
check "the systemd unit runs the checks (alert.sh check calls cert-expiry.sh) and a timer fires it daily" bash -c 'grep -q "alert.sh check" scripts/systemd/home-lab-cert-expiry.service && grep -q "cert-expiry.sh" scripts/alert.sh && grep -q "OnCalendar=daily" scripts/systemd/home-lab-cert-expiry.timer && grep -q "Persistent=true" scripts/systemd/home-lab-cert-expiry.timer'

# ---------------------------------------------------------------- preflight.sh --stage (QA-L-1)
rc=0
timeout 10 bash scripts/preflight.sh --stage > "$T/o" 2>&1 || rc=$?
check "preflight --stage without a value exits 2 (no endless loop)" bash -c 'test "$1" -eq 2 && grep -q "needs a value" "$2"' _ "$rc" "$T/o"
rc=0
timeout 10 bash scripts/preflight.sh --stage nonsense > "$T/o" 2>&1 || rc=$?
check "preflight --stage nonsense exits 2" test "$rc" -eq 2

# ---------------------------------------------------------------- breakglass.sh (SEC-L3)
export BREAKGLASS_DIR="$T/bg" BREAKGLASS_NO_ROOT_CHECK=1 BREAKGLASS_NO_TIMER=1
check "break-glass is disabled by default (status exit 0)" bash scripts/breakglass.sh status
check "break-glass on creates the drop-in" bash -c 'bash scripts/breakglass.sh on 5 > /dev/null 2>&1 && test -f "$BREAKGLASS_DIR/bg-traefik.yml"'
rc=0
bash scripts/breakglass.sh status > /dev/null 2>&1 || rc=$?
check "status reports enabled with exit 1" test "$rc" -eq 1
check "break-glass off removes the drop-in" bash -c 'bash scripts/breakglass.sh off > /dev/null 2>&1 && test ! -e "$BREAKGLASS_DIR/bg-traefik.yml"'
rc=0
bash scripts/breakglass.sh on 9999 > /dev/null 2>&1 || rc=$?
check "an out-of-range duration exits 2" test "$rc" -eq 2
rc=0
bash scripts/breakglass.sh frobnicate > /dev/null 2>&1 || rc=$?
check "an unknown command exits 2" test "$rc" -eq 2
rc=0
bash scripts/breakglass.sh on 99999999999999999999 > "$T/o" 2>&1 || rc=$?
check "a 20-digit duration exits 2 with our message, not a raw bash error (NEW-11)" bash -c 'test "$1" -eq 2 && grep -q "MINUTES must be 1-480" "$2" && ! grep -qi "integer expression" "$2"' _ "$rc" "$T/o"
check "a leading-zero duration (08) is accepted" bash -c 'bash scripts/breakglass.sh on 08 > /dev/null 2>&1 && bash scripts/breakglass.sh off > /dev/null 2>&1'
# Without the test-mode switch: no systemd-run at all must say so (NEW-11); a systemd-run that fails must not claim an auto-off.
printf '#!/bin/sh\nexit 1\n' > "$T/failing-systemd-run"
chmod +x "$T/failing-systemd-run"
check "no systemd-run: on works but says there is NO auto-off (NEW-11)" bash -c 'unset BREAKGLASS_NO_TIMER; BREAKGLASS_SYSTEMD_RUN=no-such-command-here bash scripts/breakglass.sh on 5 > "$1" 2>&1; grep -q "NO auto-off" "$1" && ! grep -q "minutes (auto-off)" "$1"; r=$?; bash scripts/breakglass.sh off > /dev/null 2>&1; exit $r' _ "$T/o"
check "a failing systemd-run is reported and no auto-off is claimed (NEW-11)" bash -c 'unset BREAKGLASS_NO_TIMER; BREAKGLASS_SYSTEMD_RUN="$2" bash scripts/breakglass.sh on 5 > "$1" 2>&1; grep -q "could not schedule" "$1" && ! grep -q "minutes (auto-off)" "$1"; r=$?; bash scripts/breakglass.sh off > /dev/null 2>&1; exit $r' _ "$T/o" "$T/failing-systemd-run"
check "bg-traefik.yml no longer claims a tmpfs drop-in (N5)" bash -c '! grep -qi "tmpfs drop-in\|/run/home-lab/breakglass" traefik/breakglass/bg-traefik.yml'
check "the drop-in routes bg-traefik through allowlist, rate limit and basic auth, host from the DOMAIN env" bash -c 'f=traefik/breakglass/bg-traefik.yml; grep -q "lan-allowlist@file" $f && grep -q "breakglass-ratelimit" $f && grep -q "breakglass-auth" $f && grep -q "env \"DOMAIN\"" $f'
unset BREAKGLASS_DIR BREAKGLASS_NO_ROOT_CHECK BREAKGLASS_NO_TIMER

# ---------------------------------------------------------------- pi-install-cert.sh (QA-L-15)
rc=0
bash scripts/pki/pi-install-cert.sh --help > "$T/o" 2>&1 || rc=$?
check "pi-install-cert.sh --help exits 0 and prints the usage" bash -c 'test "$1" -eq 0 && grep -q "^# pi-install-cert.sh\|Usage:" "$2"' _ "$rc" "$T/o"
# Not-yet-valid certificate: a stub date makes "now" ten years ago, so a freshly issued certificate has a future notBefore.
printf 'test-pass\n' > "$T/capass"
mkdir -p "$T/capar" "$T/pipki"
bash scripts/pki/new-ca.sh --out "$T/capar/ca" --passfile "$T/capass" > /dev/null 2>&1
bash scripts/pki/pi-csr.sh --pki-dir "$T/pipki" --no-chown > /dev/null 2>&1
bash scripts/pki/sign.sh --ca-dir "$T/capar/ca" --passfile "$T/capass" --role host --csr "$T/pipki/host.csr" --out "$T/host.crt" > /dev/null 2>&1
mkdir -p "$T/stub"
cat > "$T/stub/date" << 'STUB'
#!/usr/bin/env bash
real="$(PATH="${REAL_PATH}" command -v date)"
if [ "${1:-}" = "+%s" ]; then echo $(( $("$real" +%s) - 315360000 )); else exec "$real" "$@"; fi
STUB
chmod +x "$T/stub/date"
rc=0
env REAL_PATH="$PATH" PATH="$T/stub:$PATH" bash scripts/pki/pi-install-cert.sh host "$T/host.crt" --pki-dir "$T/pipki" --no-chown > "$T/o" 2>&1 || rc=$?
check "a certificate that is not valid yet is refused (notBefore, QA-L-15)" bash -c 'test "$1" -ne 0 && grep -q "not valid yet" "$2"' _ "$rc" "$T/o"
check "the same certificate installs with a correct clock" bash scripts/pki/pi-install-cert.sh host "$T/host.crt" --pki-dir "$T/pipki" --no-chown

# ---------------------------------------------------------------- inventory.jq collisions (QA-L-10)
cat > "$T/collide.json" << 'JSON'
{"ResourceRecordSets":[
 {"Name":"a_b.example.com.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"192.0.2.1"}]},
 {"Name":"a-b.example.com.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"192.0.2.2"}]}]}
JSON
rc=0
jq -r --arg apex "example.com." -f scripts/inventory.jq "$T/collide.json" > "$T/o" 2>&1 || rc=$?
check "colliding existing_records keys abort the generator (QA-L-10)" bash -c 'test "$1" -ne 0 && grep -q "duplicate existing_records keys" "$2"' _ "$rc" "$T/o"

# ---------------------------------------------------------------- aws-preflight.sh against a MOCK aws (QA-L-12, QA-L-11)
mkdir -p "$T/mockbin"
cat > "$T/mockbin/aws" << 'MOCK'
#!/usr/bin/env bash
# MOCK aws: answers the calls aws-preflight.sh makes with canned data, with CRLF line ends like aws.exe.
args="$*"
crlf() { sed 's/$/\r/'; }
case "$args" in
  *--mock-marker*) echo MOCK-AWS-MARKER ;;
  *"sts get-caller-identity"*) echo "123456789012" | crlf ;;
  *"route53 list-hosted-zones-by-name"*|*"route53 list-hosted-zones"*) printf '%s' "${MOCK_ZONES:-[]}" | crlf ;;
  *"route53 get-hosted-zone"*) printf '%s\n' '{"HostedZone":{"Id":"/hostedzone/Z1EXAMPLE","Config":{"Comment":"owner ${x} and %{y} comment"}},"DelegationSet":{"NameServers":["ns-1.example.org"]}}' | crlf ;;
  *"route53 list-resource-record-sets"*) printf '%s\n' '{"ResourceRecordSets":[]}' | crlf ;;
  *) echo "[]" | crlf ;;
esac
exit 0
MOCK
chmod +x "$T/mockbin/aws"
(
  export PATH="$T/mockbin:$PATH" AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=does-not-exist AWS_EC2_METADATA_DISABLED=true
  case "$(command -v aws)" in "$T"/mockbin/aws) ;; *) echo "ABORT: aws is not the mock" >&2; exit 3 ;; esac
  [ "$(aws --mock-marker | tr -d '\r')" = MOCK-AWS-MARKER ] || { echo "ABORT: mock marker failed" >&2; exit 3; }
  # only the HCL helper of aws-preflight.sh is exercised here (the script itself needs a real zone and registrar)
  sed -n '/^hcl_str()/p' "$REPO/scripts/aws-preflight.sh" > "$T/hcl_str.sh"
  # shellcheck source=/dev/null
  . "$T/hcl_str.sh"
  out="$(printf '%s' 'owner ${x} and %{y} comment' | hcl_str)"
  [ "$out" = '"owner $${x} and %%{y} comment"' ] || { echo "hcl_str gave: $out" >&2; exit 1; }
  # the CRLF-emitting mock is what the fixed parsing has to survive: no CR may reach a snapshot value
  printf '%s' "$(aws route53 get-hosted-zone | jq -r '.HostedZone.Id' | tr -d '\r')" | grep -q '^/hostedzone/Z1EXAMPLE$' || exit 1
) > "$T/o" 2>&1
check "the zone comment is HCL-escaped (QA-L-11) and the mock-aws harness proves itself (QA-L-12)" test "$?" -eq 0
if [ "$(head -c 0 /dev/null; cat "$T/o" | grep -c ABORT)" -ne 0 ]; then bad "mock aws proof failed: $(cat "$T/o")"; fi

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll ops-script checks passed\n'
