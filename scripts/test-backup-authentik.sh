#!/usr/bin/env bash
# test-backup-authentik.sh - offline self-test of the K5 Authentik backup: scripts/backup-authentik.sh, its systemd units and the unit
# drift list. No root, no AWS, no Docker, no network: docker, aws and age are MOCKS placed first on PATH (and PROVED to be first before any
# case runs); real credentials and AWS config are disabled. Needs bash, flock, dd, openssl is not needed.
#   success (object, marker, state file, private AWS profile, no plaintext on disk), pg_dump failing mid-stream, age failing, the upload
#   failing, a tiny dump, a failing marker upload, a missing or malformed recipient, a stopped container, the alert rate limit, the
#   OnFailure= de-duplication, the atomic state file, a second run holding the lock, and (when the real `age` is installed) a real
#   encrypt and decrypt round trip through the whole stream.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"
for t in flock dd sha256sum; do
  command -v "$t" > /dev/null || {
    echo "$t is required" >&2
    exit 2
  }
done
REAL_AGE="$(command -v age || true)"
REAL_AGE_KEYGEN="$(command -v age-keygen || true)"
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
cleanup() {
  [ -z "${LOCK_PID:-}" ] || kill "$LOCK_PID" 2> /dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

ETC="$T/etc"
STATE="$T/state"
UPLOADS="$T/uploads"
mkdir -p "$ETC/pki" "$T/mockbin" "$UPLOADS"
: > "$ETC/pki/host.crt"
: > "$ETC/pki/host.key"
RECIPIENT="age1$(printf 'q%.0s' $(seq 1 58))" # right shape, not a real key: the mock age does not parse it
BUCKET="home-lab-backup-111111111111-af-south-1"
write_env() { # write_env [recipient-line-override]
  cat > "$ETC/aws.env" << ENV
AWS_REGION=af-south-1
RA_TRUST_ANCHOR_ARN=arn:aws:rolesanywhere:af-south-1:111111111111:trust-anchor/00000000-0000-0000-0000-000000000003
RA_HOST_PROFILE_ARN=arn:aws:rolesanywhere:af-south-1:111111111111:profile/00000000-0000-0000-0000-000000000004
RA_HOST_ROLE_ARN=arn:aws:iam::111111111111:role/home-lab-pi-host
ALERT_TOPIC_ARN=arn:aws:sns:af-south-1:111111111111:home-lab-alerts
BACKUP_S3_BUCKET=$BUCKET
ENV
  if [ $# -eq 0 ]; then echo "BACKUP_AGE_RECIPIENT=$RECIPIENT" >> "$ETC/aws.env"; else printf '%s\n' "$1" >> "$ETC/aws.env"; fi
}

# ---------------------------------------------------------------- the mocks
cat > "$T/mockbin/docker" << 'MOCK'
#!/usr/bin/env bash
# MOCK docker: `inspect` says whether the container runs; `exec` plays pg_dump (a recognisable plaintext on stdout).
if [ "$*" = "--mock-marker" ]; then echo MOCK-DOCKER-MARKER; exit 0; fi
printf 'DOCKER %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  inspect) if [ -n "${MOCK_DOCKER_DOWN:-}" ]; then echo false; else echo true; fi ;;
  exec)
    printf 'PGDMP-PLAINTEXT-CANARY-'
    if [ -n "${MOCK_PG_FAIL:-}" ]; then
      head -c 3000 /dev/zero | tr '\0' x
      echo 'pg_dump: error: connection to server on socket failed' >&2
      exit 3
    fi
    head -c "${MOCK_DUMP_BYTES:-20000}" /dev/zero | tr '\0' x
    ;;
  *) exit 1 ;;
esac
MOCK
cat > "$T/mockbin/age" << 'MOCK'
#!/usr/bin/env bash
# MOCK age: rot13 behind a header (not encryption: it only lets the test see that data went through it), or the real age, or a failure.
if [ "$*" = "--mock-marker" ]; then echo MOCK-AGE-MARKER; exit 0; fi
printf 'AGE %s\n' "$*" >> "$MOCK_LOG"
if [ -n "${MOCK_AGE_REAL:-}" ]; then exec "$MOCK_AGE_REAL" "$@"; fi
if [ -n "${MOCK_AGE_FAIL:-}" ]; then
  cat > /dev/null
  echo 'age: error: failed to encrypt' >&2
  exit 1
fi
printf 'MOCK-AGE-V1\n'
tr 'A-Za-z' 'N-ZA-Mn-za-m'
MOCK
cat > "$T/mockbin/aws" << 'MOCK'
#!/usr/bin/env bash
# MOCK aws: records the call and the profile the script wrote; stores `s3 cp -` uploads under $MOCK_UPLOADS; never touches a network.
if [ "$*" = "--mock-marker" ]; then echo MOCK-AWS-MARKER; exit 0; fi
{
  printf 'ARGS %s\n' "$*"
  printf 'PROFILE %s\n' "${AWS_PROFILE:-}"
  if grep -q '^credential_process = /usr/local/bin/aws_signing_helper credential-process' "${AWS_CONFIG_FILE:-/nonexistent}" 2> /dev/null; then echo "CONFIG-OK"; fi
  printf 'MODE %s\n' "$(stat -c %a "$(dirname "${AWS_CONFIG_FILE:-/nonexistent}")" 2> /dev/null || echo none)"
} >> "$MOCK_LOG"
case "$1 $2" in
  "sns publish")
    [ -z "${MOCK_SNS_FAIL:-}" ] || {
      echo "An error occurred (AccessDenied) when calling the Publish operation: not allowed"
      exit 254
    }
    echo "11111111-2222-3333-4444-555555555555"
    ;;
  "s3 cp")
    [ "$3" = "-" ] || exit 2
    key="${4#s3://*/}"
    if { [ -n "${MOCK_AWS_FAIL:-}" ] && [[ "$key" != *.ok ]]; } || { [ -n "${MOCK_AWS_MARKER_FAIL:-}" ] && [[ "$key" == *.ok ]]; }; then
      cat > /dev/null
      echo "upload failed: An error occurred (AccessDenied) when calling the PutObject operation: Access Denied" >&2
      exit 1
    fi
    mkdir -p "$MOCK_UPLOADS/$(dirname "$key")"
    cat > "$MOCK_UPLOADS/$key"
    ;;
  *) exit 2 ;;
esac
MOCK
chmod +x "$T/mockbin/docker" "$T/mockbin/age" "$T/mockbin/aws"
export MOCK_LOG="$T/mock.log" MOCK_UPLOADS="$UPLOADS"
export PATH="$T/mockbin:$PATH"
for m in docker age aws; do
  case "$(command -v "$m")" in "$T"/mockbin/"$m") ;; *)
    echo "ABORT: $m is not the mock" >&2
    exit 3
    ;;
  esac
done
{ [ "$(docker --mock-marker)" = MOCK-DOCKER-MARKER ] && [ "$(age --mock-marker)" = MOCK-AGE-MARKER ] && [ "$(aws --mock-marker)" = MOCK-AWS-MARKER ]; } || {
  echo "ABORT: mock marker failed" >&2
  exit 3
}
ok "docker, age and aws are the mocks, first on PATH (proved with a marker call)"

# backup <env assignments...>: one run of the script with the test directories; output in $T/o, exit code in $rc.
rc=0
backup() {
  rc=0
  env HOME_LAB_ETC_DIR="$ETC" HOME_LAB_STATE_DIR="$STATE" "$@" bash scripts/backup-authentik.sh > "$T/o" 2>&1 || rc=$?
}
count() { grep -c "$1" "$MOCK_LOG" 2> /dev/null || true; }
fresh() { # fresh: empty log, no uploads, a seeded old success time, no alert state
  : > "$MOCK_LOG"
  rm -rf "${UPLOADS:?}"/* "$STATE"
  mkdir -p "$STATE"
  echo 1700000000 > "$STATE/backup-authentik.last"
}
published() { count '^ARGS sns publish'; }
uploads_n() { find "$UPLOADS" -type f | wc -l | tr -d ' '; }
state_unchanged() { [ "$(cat "$STATE/backup-authentik.last")" = 1700000000 ] && [ ! -e "$STATE/backup-authentik.last.new" ]; }

# ---------------------------------------------------------------- success
write_env
fresh
backup
obj="$(find "$UPLOADS/authentik" -name '*.dump.age' | head -n 1)"
check "success: exit 0 and a dump object plus its marker under authentik/" bash -c 'test "$1" -eq 0 && test -n "$2" && test -f "$2.ok" && test "$3" -eq 2' _ "$rc" "$obj" "$(uploads_n)"
check "success: the key is authentik/<UTC timestamp>.dump.age" bash -c 'basename "$1" | grep -Eq "^[0-9]{8}T[0-9]{6}Z\.dump\.age$"' _ "$obj"
check "success: the marker records the byte count of the object" bash -c 'grep -q "^bytes=$(wc -c < "$1" | tr -d " ")$" "$1.ok"' _ "$obj"
check "success: what was uploaded is the age output of the dump (header, rot13 of the stream)" bash -c 'head -n 1 "$1" | grep -q "^MOCK-AGE-V1$" && tail -n +2 "$1" | tr "N-ZA-Mn-za-m" "A-Za-z" | head -c 22 | grep -q "^PGDMP-PLAINTEXT-CANARY"' _ "$obj"
check "success: the plaintext canary is not in the uploaded object" bash -c '! grep -aq "PGDMP-PLAINTEXT-CANARY" "$1"' _ "$obj"
check "success: no plaintext dump anywhere under the test tree (no temp file, log or state)" bash -c '! grep -raq "PGDMP-PLAINTEXT-CANARY" "$1" --exclude-dir=mockbin' _ "$T"
check "success: pg_dump runs INSIDE the container in custom format, the password is read there (not passed in)" bash -c 'grep -q "^DOCKER exec authentik-postgresql sh -c " "$1" && grep -q "exec pg_dump" "$1" && grep -q -- "-Fc" "$1" && grep -q "/run/secrets/pg_password" "$1" && ! grep -Eq "DOCKER exec (-e|--env)" "$1"' _ "$MOCK_LOG"
check "success: age gets only the public recipient (-r age1...), no identity file" bash -c 'grep -q "^AGE -r $2$" "$1" && ! grep -q -- " -i " "$1"' _ "$MOCK_LOG" "$RECIPIENT"
check "success: the upload is 's3 cp -' to the bucket, quiet, with the host profile and a private (0700) config dir" bash -c 'grep -q "^ARGS s3 cp - s3://$2/authentik/.*\.dump\.age --no-progress --only-show-errors --region af-south-1" "$1" && grep -q "^PROFILE home-lab-host" "$1" && grep -q "^CONFIG-OK" "$1" && grep -q "^MODE 700" "$1"' _ "$MOCK_LOG" "$BUCKET"
check "success: the state file holds a current epoch, no .new file is left" bash -c 'v="$(cat "$1/backup-authentik.last")"; test $(( $(date +%s) - v )) -lt 60 && test ! -e "$1/backup-authentik.last.new"' _ "$STATE"
check "success: the state file is private (0600) and the state dir is 0700" bash -c 'test "$(stat -c %a "$1/backup-authentik.last")" = 600 && test "$(stat -c %a "$1")" = 700' _ "$STATE"
check "success: no alert sent" test "$(published)" -eq 0
check "success: the output names no credential" bash -c '! grep -Eqi "secret|session|token|BEGIN|password=" "$1"' _ "$T/o"

# ---------------------------------------------------------------- failures: every stage, and the state file stays untouched
fresh
backup MOCK_PG_FAIL=1
check "pg_dump fails mid-stream: exit 1, says pg_dump, NO marker, state file untouched" bash -c 'test "$1" -eq 1 && grep -q "pg_dump failed" "$2" && ! find "$3" -name "*.ok" | grep -q . && test "$4" = ok' _ "$rc" "$T/o" "$UPLOADS" "$(state_unchanged && echo ok)"
check "pg_dump fails: the alert goes out once with the key backup-authentik-failed text" bash -c 'test "$(grep -c "^ARGS sns publish" "$1")" -eq 1 && grep -q -- "--subject=home-lab CRITICAL: Authentik backup failed" "$1"' _ "$MOCK_LOG"
check "pg_dump fails: the alert names the reason and the runbook, not a credential" bash -c 'a="$(sed -n "/^ARGS sns publish/,\$p" "$1")"; printf "%s" "$a" | grep -q "pg_dump failed" && printf "%s" "$a" | grep -q "authentik-backup.md" && ! printf "%s" "$a" | grep -Eqi "secret|BEGIN|password"' _ "$MOCK_LOG"
check "pg_dump fails: the specific alert leaves the marker that stops the OnFailure= mail" test -f "$STATE/.check-alerted-$(printf '%s' home-lab-backup-authentik.service | sha256sum | cut -c1-16)"

fresh
backup MOCK_AGE_FAIL=1
check "age fails: exit 1, says age, no marker, state untouched" bash -c 'test "$1" -eq 1 && grep -q "age encryption failed" "$2" && ! find "$3" -name "*.ok" | grep -q . && test "$4" = ok' _ "$rc" "$T/o" "$UPLOADS" "$(state_unchanged && echo ok)"
check "age fails: the alert goes out" test "$(published)" -eq 1

fresh
backup MOCK_AWS_FAIL=1
check "upload fails: exit 1, says the upload failed with the AWS reason, no marker, state untouched" bash -c 'test "$1" -eq 1 && grep -q "S3 upload failed" "$2" && grep -q "AccessDenied" "$2" && ! find "$3" -name "*.ok" | grep -q . && test "$4" = ok' _ "$rc" "$T/o" "$UPLOADS" "$(state_unchanged && echo ok)"
check "upload fails: the alert goes out" test "$(published)" -eq 1

fresh
backup MOCK_DUMP_BYTES=100
check "tiny dump: exit 1, says how small it is, the object has NO marker, state untouched" bash -c 'test "$1" -eq 1 && grep -q "only [0-9]* bytes" "$2" && ! find "$3" -name "*.ok" | grep -q . && test "$4" = ok' _ "$rc" "$T/o" "$UPLOADS" "$(state_unchanged && echo ok)"
fresh
backup MOCK_DUMP_BYTES=100 HOME_LAB_BACKUP_MIN_BYTES=50
check "the minimum size is configurable (a 123 byte stream passes a 50 byte minimum)" test "$rc" -eq 0

fresh
backup MOCK_AWS_MARKER_FAIL=1
check "marker upload fails: exit 1, state untouched (the object exists but is not vouched for)" bash -c 'test "$1" -eq 1 && grep -q "completion marker failed" "$2" && test "$3" = ok' _ "$rc" "$T/o" "$(state_unchanged && echo ok)"

# ---------------------------------------------------------------- configuration
fresh
write_env "BACKUP_AGE_RECIPIENT="
backup
check "missing recipient: exit 1, a clear message, no docker exec and no S3 upload" bash -c 'test "$1" -eq 1 && grep -q "BACKUP_AGE_RECIPIENT is missing" "$2" && test "$(grep -c "^DOCKER exec" "$3")" -eq 0 && test "$(grep -c "^ARGS s3" "$3")" -eq 0' _ "$rc" "$T/o" "$MOCK_LOG"
check "missing recipient: the alert still goes out (a backup that cannot run is a finding)" test "$(published)" -eq 1
for badrec in "age1short" "AGE1$(printf 'q%.0s' $(seq 1 58))" "age1$(printf 'q%.0s' $(seq 1 57))b" "$RECIPIENT -o /tmp/x" "-i /etc/shadow"; do
  fresh
  write_env "BACKUP_AGE_RECIPIENT=$badrec"
  backup
  check "malformed recipient '${badrec:0:24}...' is refused before anything runs" bash -c 'test "$1" -eq 1 && test "$(grep -c "^AGE" "$2")" -eq 0 && test "$(grep -c "^DOCKER exec" "$2")" -eq 0' _ "$rc" "$MOCK_LOG"
done
fresh
write_env
sed -i '/^BACKUP_S3_BUCKET=/d' "$ETC/aws.env"
backup
check "missing bucket: exit 1 with a clear message, nothing runs" bash -c 'test "$1" -eq 1 && grep -q "BACKUP_S3_BUCKET is missing" "$2" && test "$(grep -c "^DOCKER exec" "$3")" -eq 0' _ "$rc" "$T/o" "$MOCK_LOG"
fresh
write_env
sed -i 's#^BACKUP_S3_BUCKET=.*#BACKUP_S3_BUCKET=Bad Bucket;rm#' "$ETC/aws.env"
backup
check "a malformed bucket name is refused" bash -c 'test "$1" -eq 1 && grep -q "BACKUP_S3_BUCKET is missing or malformed" "$2"' _ "$rc" "$T/o"
write_env
fresh
backup MOCK_DOCKER_DOWN=1
check "database container not running: exit 1, no dump attempted" bash -c 'test "$1" -eq 1 && grep -q "is not running" "$2" && test "$(grep -c "^DOCKER exec" "$3")" -eq 0' _ "$rc" "$T/o" "$MOCK_LOG"

# ---------------------------------------------------------------- alert rate limit and OnFailure= de-duplication
fresh
backup MOCK_PG_FAIL=1
backup MOCK_PG_FAIL=1
check "rate limit: two failing runs in a row send ONE alert" test "$(published)" -eq 1
check "rate limit: the second run says the alert was suppressed" grep -q suppressed "$T/o"
echo $(($(date +%s) - 25 * 3600)) > "$STATE/alert-backup-authentik-failed.last"
backup MOCK_PG_FAIL=1
check "rate limit: after 25 hours the next failure alerts again" test "$(published)" -eq 2
: > "$MOCK_LOG"
env HOME_LAB_ETC_DIR="$ETC" HOME_LAB_STATE_DIR="$STATE" HOME_LAB_UPTIME_FILE=/proc/uptime bash scripts/alert.sh unit-failed home-lab-backup-authentik.service > "$T/o2" 2>&1
check "OnFailure= right after the specific alert: alert.sh unit-failed sends no second mail" bash -c 'grep -q "no second mail" "$1" && test "$(grep -c "^ARGS sns publish" "$2")" -eq 0' _ "$T/o2" "$MOCK_LOG"

# ---------------------------------------------------------------- state file atomicity, lock
fresh
mkdir "$STATE/backup-authentik.last.new" # the rename source cannot be written: the run must fail and leave the old state intact
backup
check "state file: if the new state cannot be written the old one is kept and the run fails" bash -c 'test "$1" -eq 1 && test "$(cat "$2/backup-authentik.last")" = 1700000000' _ "$rc" "$STATE"
fresh
echo "garbage" > "$STATE/backup-authentik.last.new" # a stale partial file from a crashed run is simply replaced
backup
check "state file: a stale .new file from a crashed run is replaced, the result is a plain epoch" bash -c 'test "$1" -eq 0 && grep -Eq "^[0-9]{10}$" "$2/backup-authentik.last" && test ! -e "$2/backup-authentik.last.new"' _ "$rc" "$STATE"
check "state file: written by rename (mv -f of a .new file in the same directory), never in place" bash -c 'grep -Fq "$1" scripts/backup-authentik.sh' _ 'mv -f "$STATE_FILE.new" "$STATE_FILE"'

fresh
(
  exec 9> "$STATE/.backup.lock"
  flock -n 9
  sleep 20
) &
LOCK_PID=$!
sleep 1
backup
kill "$LOCK_PID" 2> /dev/null || true
wait "$LOCK_PID" 2> /dev/null || true
LOCK_PID=""
check "a second run while one holds the lock exits 0 and does nothing" bash -c 'test "$1" -eq 0 && grep -q "another backup run" "$2" && test "$(grep -c "^DOCKER exec" "$3")" -eq 0' _ "$rc" "$T/o" "$MOCK_LOG"

# ---------------------------------------------------------------- real age round trip (only where age is installed)
if [ -n "$REAL_AGE" ] && [ -n "$REAL_AGE_KEYGEN" ]; then
  "$REAL_AGE_KEYGEN" -o "$T/id.txt" > /dev/null 2>&1
  real_rec="$("$REAL_AGE_KEYGEN" -y "$T/id.txt")"
  fresh
  write_env "BACKUP_AGE_RECIPIENT=$real_rec"
  backup MOCK_AGE_REAL="$REAL_AGE"
  obj="$(find "$UPLOADS/authentik" -name '*.dump.age' | head -n 1)"
  check "real age: the stream is encrypted with the recipient and the owner's identity decrypts it to the exact dump" bash -c 'test "$1" -eq 0 && "$2" -d -i "$3" "$4" > "$5/dec.out" && { printf "PGDMP-PLAINTEXT-CANARY-"; head -c 20000 /dev/zero | tr "\0" x; } | cmp -s - "$5/dec.out"' _ "$rc" "$REAL_AGE" "$T/id.txt" "$obj" "$T"
  check "real age: the object does not contain the plaintext" bash -c '! grep -aq "PGDMP-PLAINTEXT-CANARY" "$1"' _ "$obj"
else
  printf 'SKIP  real age round trip (age and age-keygen not installed here; CI and the container run installs them)\n'
fi

# ---------------------------------------------------------------- preflight.sh check_backup (extracted, run with stubs)
sed -n '/^check_backup() {/,/^}/p' scripts/preflight.sh > "$T/check_backup.sh"
check "preflight.sh has a check_backup function to test" test -s "$T/check_backup.sh"
pf() { # pf <aws.env content> <last-success epoch or empty> : prints the verdict lines of check_backup
  local envc="$1" last="${2:-}"
  mkdir -p "$T/pf-etc" "$T/pf-state"
  printf '%b' "$envc" > "$T/pf-etc/aws.env"
  rm -f "$T/pf-state/backup-authentik.last"
  [ -z "$last" ] || echo "$last" > "$T/pf-state/backup-authentik.last"
  env ETC_DIR="$T/pf-etc" HOME_LAB_STATE_DIR="$T/pf-state" bash -c '
    . scripts/lib/common.sh
    pass() { printf "[PASS] %s %s\n" "$1" "${2:-}"; }
    warnx() { printf "[WARN] %s %s\n" "$1" "${2:-}"; }
    fail() { printf "[FAIL] %s %s\n" "$1" "${2:-}"; }
    hint() { :; }
    . "$1"
    check_backup' _ "$T/check_backup.sh"
}
GOOD_ENV="BACKUP_AGE_RECIPIENT=$RECIPIENT\nBACKUP_S3_BUCKET=$BUCKET\n"
NOW="$(date +%s)"
out="$(pf "BACKUP_S3_BUCKET=$BUCKET\n" "")"
check "preflight: recipient missing -> WARN backup-recipient, and 'never' -> WARN backup-last, no FAIL" bash -c 'printf "%s" "$1" | grep -q "^\[WARN\] backup-recipient" && printf "%s" "$1" | grep -q "^\[WARN\] backup-last.*never" && ! printf "%s" "$1" | grep -q "^\[FAIL\]"' _ "$out"
out="$(pf "$GOOD_ENV" "")"
check "preflight: configured but never run -> PASS recipient and bucket, WARN backup-last (never), with the command to start it" bash -c 'printf "%s" "$1" | grep -q "^\[PASS\] backup-recipient" && printf "%s" "$1" | grep -q "^\[PASS\] backup-bucket" && printf "%s" "$1" | grep -q "^\[WARN\] backup-last.*never.*systemctl start"' _ "$out"
out="$(pf "$GOOD_ENV" "$((NOW - 3600))")"
check "preflight: a backup 1 hour ago -> PASS" bash -c 'printf "%s" "$1" | grep -q "^\[PASS\] backup-last"' _ "$out"
out="$(pf "$GOOD_ENV" "$((NOW - 2 * 86400 + 600))")"
check "preflight: just under 2 days -> PASS" bash -c 'printf "%s" "$1" | grep -q "^\[PASS\] backup-last"' _ "$out"
out="$(pf "$GOOD_ENV" "$((NOW - 3 * 86400))")"
check "preflight: 3 days old -> WARN" bash -c 'printf "%s" "$1" | grep -q "^\[WARN\] backup-last.*3 days"' _ "$out"
out="$(pf "$GOOD_ENV" "$((NOW - 7 * 86400 + 600))")"
check "preflight: just under 7 days -> still WARN" bash -c 'printf "%s" "$1" | grep -q "^\[WARN\] backup-last"' _ "$out"
out="$(pf "$GOOD_ENV" "$((NOW - 8 * 86400))")"
check "preflight: 8 days old -> FAIL" bash -c 'printf "%s" "$1" | grep -q "^\[FAIL\] backup-last.*8 days"' _ "$out"
out="$(pf "$GOOD_ENV" "$((NOW + 86400))")"
check "preflight: a time in the future (no RTC) -> WARN, not a PASS" bash -c 'printf "%s" "$1" | grep -q "^\[WARN\] backup-last.*future"' _ "$out"
out="$(pf "$GOOD_ENV" "banana")"
check "preflight: a garbage state file counts as never (WARN)" bash -c 'printf "%s" "$1" | grep -q "^\[WARN\] backup-last.*never"' _ "$out"
out="$(pf "BACKUP_AGE_RECIPIENT=age1short\nBACKUP_S3_BUCKET=$BUCKET\n" "$((NOW - 3600))")"
check "preflight: a malformed recipient is a WARN" bash -c 'printf "%s" "$1" | grep -q "^\[WARN\] backup-recipient"' _ "$out"
check "preflight: the timer is in the timer list and age is in the installed-tools check" bash -c 'grep -q "home-lab-backup-authentik.timer; do" scripts/preflight.sh && grep -q "command -v age" scripts/preflight.sh'

# ---------------------------------------------------------------- render-aws-env.sh (terraform is a mock too)
cat > "$T/mockbin/terraform" << 'MOCK'
#!/usr/bin/env bash
# MOCK terraform: only `output -raw <name>`.
for a in "$@"; do last="$a"; done
case "$last" in
  trust_anchor_arn) printf 'arn:aws:rolesanywhere:af-south-1:111111111111:trust-anchor/00000000-0000-0000-0000-000000000003' ;;
  host_profile_arn) printf 'arn:aws:rolesanywhere:af-south-1:111111111111:profile/00000000-0000-0000-0000-000000000004' ;;
  host_role_arn) printf 'arn:aws:iam::111111111111:role/home-lab-pi-host' ;;
  alert_topic_arn) printf 'arn:aws:sns:af-south-1:111111111111:home-lab-alerts' ;;
  backup_bucket_name) [ -n "${MOCK_NO_BUCKET:-}" ] || printf 'home-lab-backup-111111111111-af-south-1' ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$T/mockbin/terraform"
rc=0
bash scripts/render-aws-env.sh --age-recipient "$RECIPIENT" > "$T/o" 2> "$T/e" || rc=$?
check "render-aws-env prints BACKUP_S3_BUCKET and BACKUP_AGE_RECIPIENT next to the existing lines" bash -c 'test "$1" -eq 0 && grep -q "^BACKUP_S3_BUCKET=home-lab-backup-111111111111-af-south-1$" "$2" && grep -q "^BACKUP_AGE_RECIPIENT=$3$" "$2" && grep -q "^ALERT_TOPIC_ARN=" "$2" && grep -q "^RA_HOST_ROLE_ARN=" "$2"' _ "$rc" "$T/o" "$RECIPIENT"
rc=0
bash scripts/render-aws-env.sh > "$T/o" 2> "$T/e" || rc=$?
check "render-aws-env without --age-recipient prints a note on stderr and no BACKUP_AGE_RECIPIENT line" bash -c 'test "$1" -eq 0 && ! grep -q "^BACKUP_AGE_RECIPIENT" "$2" && grep -q "no --age-recipient" "$3"' _ "$rc" "$T/o" "$T/e"
# built in pieces so that the public gitleaks rule age-secret-key does not flag this file
fake_identity="AGE-SECRET-""KEY-1$(printf 'Q%.0s' $(seq 1 58))"
for badrec in "$fake_identity" "age1short" "$RECIPIENT;id"; do
  rc=0
  bash scripts/render-aws-env.sh --age-recipient "$badrec" > "$T/o" 2> "$T/e" || rc=$?
  check "render-aws-env refuses '${badrec:0:20}...' (exit 2, nothing printed, the value is not echoed)" bash -c 'test "$1" -eq 2 && ! test -s "$2" && ! grep -q "SECRET-KEY-1" "$3"' _ "$rc" "$T/o" "$T/e"
done

# ---------------------------------------------------------------- units, drift list, hardening
SVC=scripts/systemd/home-lab-backup-authentik.service
TMR=scripts/systemd/home-lab-backup-authentik.timer
check "the service runs scripts/backup-authentik.sh as a oneshot and fails over to the alert handler (OnFailure=)" bash -c 'grep -q "^ExecStart=@REPO_DIR@/scripts/backup-authentik.sh$" "$1" && grep -q "^Type=oneshot" "$1" && grep -q "^OnFailure=home-lab-alert-failure@%n.service" "$1"' _ "$SVC"
check "the service keeps what docker exec allows: no new privileges, private tmp, read-only system, no kernel or clock access" bash -c 'for k in NoNewPrivileges=true PrivateTmp=true ProtectSystem=strict ProtectHome=true ProtectKernelTunables=true ProtectKernelModules=true ProtectKernelLogs=true ProtectControlGroups=true ProtectClock=true RestrictRealtime=true LockPersonality=true RestrictSUIDSGID=true; do grep -q "^$k\$" "$1" || { echo "missing $k"; exit 1; }; done' _ "$SVC"
check "the service documents why it is root and keeps /var/lib/home-lab as its state directory" bash -c 'grep -qi "root" "$1" && grep -q "^StateDirectory=home-lab" "$1"' _ "$SVC"
check "the timer is nightly, randomised and persistent" bash -c 'grep -q "^OnCalendar=" "$1" && grep -q "^RandomizedDelaySec=" "$1" && grep -q "^Persistent=true" "$1" && grep -q "^WantedBy=timers.target" "$1"' _ "$TMR"
check "the unit drift list covers both new units" bash -c '. scripts/lib/common.sh; . scripts/lib/units.sh; printf "%s\n" "${LAB_UNITS[@]}" | grep -qx home-lab-backup-authentik.service && printf "%s\n" "${LAB_UNITS[@]}" | grep -qx home-lab-backup-authentik.timer'
check "bootstrap.sh enables the timer and installs age from apt" bash -c 'grep -q "home-lab-backup-authentik.timer" scripts/bootstrap.sh && grep -Eq "age:age|age " scripts/bootstrap.sh'
if command -v systemd-analyze > /dev/null 2>&1; then
  vd="$T/units"
  mkdir -p "$vd"
  for u in home-lab-backup-authentik.service home-lab-backup-authentik.timer home-lab-alert-failure@.service; do
    sed "s#@REPO_DIR@#$REPO#g; s#@APPS_ROOT@#/apps#g" "scripts/systemd/$u" > "$vd/$u"
  done
  printf '[Service]
ExecStart=/bin/true
' > "$vd/docker.service" # a stand-in: the container has no Docker
  out="$(systemd-analyze verify --man=no "$vd/home-lab-backup-authentik.service" "$vd/home-lab-backup-authentik.timer" 2>&1 || true)"
  check "systemd-analyze verify is clean for the new units" bash -c '! printf "%s" "$1" | grep -E "home-lab-backup-authentik" | grep -Eqi "error|invalid|unknown|failed"' _ "$out"
else
  printf 'SKIP  systemd-analyze verify (not installed here)\n'
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "Authentik backup self-test: all checks passed"
else
  echo "Authentik backup self-test: $fails FAILED"
  exit 1
fi
