#!/usr/bin/env bash
# test-backup-apps.sh - offline self-test of scripts/backup-apps.sh (R17 app backups) and its systemd units. No root, no AWS, no Docker,
# no network: docker, aws and age are MOCKS placed first on PATH (and PROVED to be first before any case runs); tar is the real one.
#   Success for every job (objects, markers, the state file, no plaintext anywhere), the excludes (Home Assistant history database, Pi-hole
#   query log), apps that are not installed (skipped), a stopped database (that job fails, the others still upload, one alert), age and
#   upload failures, a missing recipient, a restore in progress, and the units.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
for t in flock dd sha256sum tar; do
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
trap 'rm -rf "$T"' EXIT
ETC="$T/etc"
STATE="$T/state"
UPLOADS="$T/uploads"
APPS="$T/apps"
mkdir -p "$ETC/pki" "$T/mockbin" "$UPLOADS"
: > "$ETC/pki/host.crt"
: > "$ETC/pki/host.key"
RECIPIENT="age1$(printf 'q%.0s' $(seq 1 58))"
BUCKET="home-lab-backup-111111111111-af-south-1"
write_env() {
  cat > "$ETC/aws.env" << ENV
AWS_REGION=af-south-1
RA_TRUST_ANCHOR_ARN=arn:aws:rolesanywhere:af-south-1:111111111111:trust-anchor/00000000-0000-0000-0000-000000000003
RA_HOST_PROFILE_ARN=arn:aws:rolesanywhere:af-south-1:111111111111:profile/00000000-0000-0000-0000-000000000004
RA_HOST_ROLE_ARN=arn:aws:iam::111111111111:role/home-lab-pi-host
ALERT_TOPIC_ARN=arn:aws:sns:af-south-1:111111111111:home-lab-alerts
BACKUP_S3_BUCKET=$BUCKET
ENV
  if [ $# -eq 0 ]; then echo "BACKUP_AGE_RECIPIENT=$RECIPIENT" >> "$ETC/aws.env"; fi
}
# The app directories, with a plaintext canary in every file (it must never reach an upload or a disk outside APPS).
make_apps() {
  rm -rf "$APPS"
  mkdir -p "$APPS/linkwarden/data/archives" "$APPS/homeassistant/config/.storage" "$APPS/pihole/etc-pihole" "$APPS/portainer/data"
  for f in linkwarden/data/archives/page.pdf homeassistant/config/configuration.yaml homeassistant/config/.storage/http \
    homeassistant/config/home-assistant_v2.db homeassistant/config/home-assistant_v2.db-wal pihole/etc-pihole/pihole.toml \
    pihole/etc-pihole/gravity.db pihole/etc-pihole/pihole-FTL.db portainer/data/portainer.db; do
    { printf 'APPS-PLAINTEXT-CANARY-%s ' "$f"; head -c 3000 /dev/zero | tr '\0' z; } > "$APPS/$f"
  done
}

cat > "$T/mockbin/docker" << 'MOCK'
#!/usr/bin/env bash
# MOCK docker: `inspect <name>` says whether it exists, `inspect -f` whether it runs; `exec` plays pg_dump.
if [ "$*" = "--mock-marker" ]; then echo MOCK-DOCKER-MARKER; exit 0; fi
printf 'DOCKER %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  inspect)
    [ -z "${MOCK_PG_ABSENT:-}" ] || exit 1
    if [ "$2" = -f ]; then if [ -n "${MOCK_PG_DOWN:-}" ]; then echo false; else echo true; fi; fi
    ;;
  exec)
    printf 'PGDMP-PLAINTEXT-CANARY-'
    head -c 20000 /dev/zero | tr '\0' x
    ;;
  *) exit 1 ;;
esac
MOCK
cat > "$T/mockbin/age" << 'MOCK'
#!/usr/bin/env bash
# MOCK age: rot13 behind a header (not encryption: it lets the test see the data went through it), or a failure.
if [ "$*" = "--mock-marker" ]; then echo MOCK-AGE-MARKER; exit 0; fi
printf 'AGE %s\n' "$*" >> "$MOCK_LOG"
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
# MOCK aws: stores `s3 cp -` uploads under $MOCK_UPLOADS; `sns publish` answers a message id; never touches a network.
if [ "$*" = "--mock-marker" ]; then echo MOCK-AWS-MARKER; exit 0; fi
printf 'ARGS %s\n' "$*" >> "$MOCK_LOG"
case "$1 $2" in
  "sns publish") echo "11111111-2222-3333-4444-555555555555" ;;
  "s3 cp")
    [ "$3" = "-" ] || exit 2
    key="${4#s3://*/}"
    if [ -n "${MOCK_AWS_FAIL:-}" ] && [[ "$key" != *.ok ]]; then
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

rc=0
backup() {
  rc=0
  env HOME_LAB_ETC_DIR="$ETC" HOME_LAB_STATE_DIR="$STATE" HOME_LAB_APPS_ROOT="$APPS" "$@" bash scripts/backup-apps.sh > "$T/o" 2>&1 || rc=$?
}
fresh() {
  : > "$MOCK_LOG"
  rm -rf "${UPLOADS:?}"/* "$STATE"
  mkdir -p "$STATE"
  echo 1700000000 > "$STATE/backup-apps.last"
  make_apps
}
obj() { find "$UPLOADS/apps/$1" -name "*.$2.age" 2> /dev/null | head -n 1; }
markers() { find "$UPLOADS" -name '*.ok' | wc -l | tr -d ' '; }
published() { grep -c '^ARGS sns publish' "$MOCK_LOG" 2> /dev/null || true; }
state_unchanged() { [ "$(cat "$STATE/backup-apps.last")" = 1700000000 ]; }
unmask_tar() { tail -n +2 "$1" | tr 'N-ZA-Mn-za-m' 'A-Za-z' | tar -tf -; }
export -f unmask_tar

# ---------------------------------------------------------------- success
write_env
fresh
backup
check "success: exit 0" test "$rc" -eq 0
for j in linkwarden-data homeassistant pihole portainer; do
  o="$(obj "$j" tar)"
  check "success: apps/$j/<UTC>.tar.age with its marker" bash -c 'test -n "$1" && test -f "$1.ok" && basename "$1" | grep -Eq "^[0-9]{8}T[0-9]{6}Z\.tar\.age$"' _ "$o"
done
o="$(obj linkwarden-db dump)"
check "success: apps/linkwarden-db/<UTC>.dump.age with its marker" bash -c 'test -n "$1" && test -f "$1.ok"' _ "$o"
check "success: five objects and five markers, nothing else" test "$(find "$UPLOADS" -type f | wc -l | tr -d ' ')$(markers)" = 105
check "success: the dump is read inside linkwarden-postgresql with ITS password file (never an argument here)" bash -c 'grep -q "^DOCKER exec linkwarden-postgresql sh -c PGPASSWORD=\"\$(cat \"/run/secrets/lw_pg_password\")\" exec pg_dump" "$1"' _ "$MOCK_LOG"
check "success: every object went through age (header) and holds no plaintext canary" bash -c 'for f in $(find "$1" -name "*.age"); do head -n 1 "$f" | grep -q "^MOCK-AGE-V1$" || exit 1; grep -aq "PLAINTEXT-CANARY" "$f" && exit 1; done; exit 0' _ "$UPLOADS"
check "success: no plaintext copy anywhere outside the app directories (temp files, logs, state)" bash -c '! grep -raq "PLAINTEXT-CANARY" "$1" --exclude-dir=apps --exclude-dir=mockbin' _ "$T"
check "success: the state file holds a fresh epoch, the marker records the byte count" bash -c '[ "$(cat "$1/backup-apps.last")" -gt 1700000000 ] && grep -q "^bytes=$(wc -c < "$2" | tr -d " ")$" "$2.ok"' _ "$STATE" "$(obj portainer tar)"
check "excludes: the Home Assistant backup has the config and .storage but NOT the history database (home-assistant_v2.db*)" bash -c 'l="$(unmask_tar "$1")"; grep -qx "config/configuration.yaml" <<< "$l" && grep -qx "config/.storage/http" <<< "$l" && ! grep -q "home-assistant_v2.db" <<< "$l"' _ "$(obj homeassistant tar)"
check "excludes: the Pi-hole backup has the settings and lists but NOT the query log (pihole-FTL.db)" bash -c 'l="$(unmask_tar "$1")"; grep -qx "etc-pihole/pihole.toml" <<< "$l" && grep -qx "etc-pihole/gravity.db" <<< "$l" && ! grep -q "pihole-FTL.db" <<< "$l"' _ "$(obj pihole tar)"
check "success: no alert was sent" test "$(published)" = 0

# ---------------------------------------------------------------- apps not installed yet
fresh
rm -rf "$APPS/portainer" "$APPS/homeassistant"
backup MOCK_PG_ABSENT=1
check "not installed: Portainer, Home Assistant and the Linkwarden database are skipped, the rest is backed up, exit 0" bash -c 'test "$1" -eq 0 && [ -z "$(find "$2/apps" -path "*portainer*" -o -path "*homeassistant*" -o -path "*linkwarden-db*" | head -1)" ] && [ "$3" = 2 ] && grep -q "skipped" "$4"' _ "$rc" "$UPLOADS" "$(markers)" "$T/o"

# ---------------------------------------------------------------- one job fails, the others still run
fresh
backup MOCK_PG_DOWN=1
check "database stopped: exit 1, the four file backups still uploaded with markers, none for linkwarden-db" bash -c 'test "$1" -eq 1 && [ "$2" = 4 ] && [ -z "$(find "$3/apps/linkwarden-db" -type f 2>/dev/null | head -1)" ]' _ "$rc" "$(markers)" "$UPLOADS"
check "database stopped: ONE alert naming the failed job and the ones that succeeded; the state file is unchanged" bash -c '[ "$1" = 1 ] && grep -q "linkwarden-db (container not running)" "$2" && grep -q "succeeded: linkwarden-data homeassistant pihole portainer" "$2"' _ "$(published)" "$T/o"
check "database stopped: the state file keeps the old time" state_unchanged

fresh
backup MOCK_AGE_FAIL=1
check "age fails: exit 1, no marker at all, state unchanged" bash -c 'test "$1" -eq 1 && [ "$2" = 0 ]' _ "$rc" "$(markers)"
check "age fails: the state file keeps the old time" state_unchanged
fresh
backup MOCK_AWS_FAIL=1
check "upload fails: exit 1, no marker, the reason is logged" bash -c 'test "$1" -eq 1 && [ "$2" = 0 ] && grep -q "S3 upload failed" "$3"' _ "$rc" "$(markers)" "$T/o"

# ---------------------------------------------------------------- configuration and recovery
write_env no-recipient
fresh
backup
check "no recipient: exit 1 before any upload" bash -c 'test "$1" -eq 1 && [ -z "$(find "$2" -type f | head -1)" ]' _ "$rc" "$UPLOADS"
write_env
fresh
: > "$ETC/restore-pending"
backup
check "restore in progress: nothing backed up, exit 0, no alert" bash -c 'test "$1" -eq 0 && [ -z "$(find "$2" -type f | head -1)" ] && [ "$3" = 0 ]' _ "$rc" "$UPLOADS" "$(published)"
rm -f "$ETC/restore-pending"

# ---------------------------------------------------------------- units
svc=scripts/systemd/home-lab-backup-apps.service
check "the service has exactly the Authentik backup's hardening block (same sandbox)" bash -c 'diff <(sed -n "/^ProtectSystem=/,/^Nice=/p" "$1") <(sed -n "/^ProtectSystem=/,/^Nice=/p" scripts/systemd/home-lab-backup-authentik.service)' _ "$svc"
check "the service runs scripts/backup-apps.sh with OnFailure alerting, after the Authentik backup" bash -c 'grep -q "^ExecStart=@REPO_DIR@/scripts/backup-apps.sh$" "$1" && grep -q "^OnFailure=home-lab-alert-failure@%n.service$" "$1" && grep -q "^After=.*home-lab-backup-authentik.service" "$1"' _ "$svc"
check "the timer runs nightly at 03:15 (after the Authentik window), persistent" bash -c 'grep -q "^OnCalendar=\*-\*-\* 03:15:00$" "$1" && grep -q "^Persistent=true$" "$1"' _ scripts/systemd/home-lab-backup-apps.timer
check "units.sh, bootstrap.sh and preflight.sh know the new units" bash -c 'grep -q "home-lab-backup-apps.timer" scripts/lib/units.sh && grep -q "home-lab-backup-apps.timer" scripts/bootstrap.sh && grep -q "home-lab-backup-apps.timer" scripts/preflight.sh'

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll app backup checks passed\n'
