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
  if [ "${DEBUG_BACKUP:-0}" = 1 ]; then sed "s/^/    | /" "$T/o"; fi
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

# ---------------------------------------------------------------- R19 jobs: SQLite (koffan-db, n8n-db), n8n-files, couchdb
# These use the REAL sqlite3 (a WAL-mode fixture held open by a second connection, so the -wal file really exists) and a MOCK setpriv that
# records its arguments and runs the command as the current user. The uid switch itself needs root and is therefore proved on the Pi
# (docs/runbooks/r19-apps.md); here the test proves WHAT the script asks setpriv to do and that no file in the app directory changes.
echo "--- R19 jobs"
cat > "$T/mockbin/setpriv" << 'MOCK'
#!/usr/bin/env bash
# MOCK setpriv: records the call, strips the leading --reuid/--regid/--clear-groups options and runs the rest as the current user.
if [ "$*" = "--mock-marker" ]; then echo MOCK-SETPRIV-MARKER; exit 0; fi
printf 'SETPRIV %s\n' "$*" >> "$MOCK_LOG"
while [ $# -gt 0 ]; do
  case "$1" in --reuid=* | --regid=* | --clear-groups | --inh-caps=* | --ambient-caps=*) shift ;; *) break ;; esac
done
exec "$@"
MOCK
chmod +x "$T/mockbin/setpriv"
[ "$(setpriv --mock-marker 2> /dev/null)" = MOCK-SETPRIV-MARKER ] || {
  echo "ABORT: setpriv is not the mock" >&2
  exit 3
}
REAL_SQLITE3="$(command -v sqlite3 2> /dev/null || true)"
if [ -z "$REAL_SQLITE3" ] || [ ! -d /dev/shm ] || [ "$(id -u)" -eq 0 ] || [ "$(stat -f -c %T /dev/shm 2> /dev/null)" != tmpfs ]; then
  if [ "${REQUIRE_SQLITE:-0}" = 1 ]; then
    bad "R19 SQLite jobs need a real sqlite3, a tmpfs /dev/shm and a non-root user (REQUIRE_SQLITE=1: a skip is a failure)"
  else
    printf 'SKIP  R19 SQLite jobs (needs sqlite3, a tmpfs /dev/shm and a non-root user; CI runs them)\n'
  fi
  SQLITE_OK=0
else
  SQLITE_OK=1
fi
check "the R19 jobs are in the job list; Speedtest Tracker has no job" bash -c 'j="$(sed -n "/^JOBS=(/,/^)/p" scripts/backup-apps.sh)"; for n in koffan-db n8n-db n8n-files couchdb; do grep -q "\"$n|" <<< "$j" || exit 1; done; ! grep -qi speedtest <<< "$j"'
check "the script refuses to run sqlite3 as root (owner uid 0) and only ever as the owner through setpriv" bash -c 'grep -q "refusing to run sqlite3 as root next to a live database" scripts/lib/backup-streams.sh && grep -q "setpriv --reuid=\"\$uid\" --regid=\"\$gid\" --clear-groups" scripts/lib/backup-streams.sh'

mk_r19_apps() {
  rm -rf "$APPS"
  mkdir -p "$APPS/koffan/data" "$APPS/n8n/data/binaryData/nested" "$APPS/speedtest/config" "$APPS/couchdb/data/.shards/00000000-7fffffff/obsidian" \
    "$APPS/couchdb/data/shards/00000000-7fffffff" "$APPS/couchdb/etc"
  printf 'N8N-FILES-PLAINTEXT-CANARY ' > "$APPS/n8n/data/config"
  head -c 3000 /dev/zero | tr '\0' z >> "$APPS/n8n/data/config"
  printf 'x' > "$APPS/n8n/data/binaryData/file1"
  printf "NESTED-CONFIG" > "$APPS/n8n/data/binaryData/nested/config"
  printf 'SPEEDTEST-CANARY' > "$APPS/speedtest/config/database.sqlite"
  for f in data/.shards/00000000-7fffffff/obsidian/db.1.couch data/shards/00000000-7fffffff/obsidian.1.couch data/_dbs.couch data/_nodes.couch etc/docker.ini; do
    { printf 'COUCH-PLAINTEXT-CANARY-%s ' "$f"; head -c 3000 /dev/zero | tr '\0' c; } > "$APPS/couchdb/$f"
  done
}
# hold_wal <db>: a WAL-mode database with 400 rows whose writer connection stays open (so -wal and -shm exist) until unhold.
HOLD_PIDS=()
hold_wal() {
  local db="$1"
  rm -f "$db" "$db-wal" "$db-shm"
  (
    printf '%s\n' "PRAGMA journal_mode=WAL;" "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT);" \
      "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<400) INSERT INTO items(name) SELECT 'SQLITE-PLAINTEXT-CANARY-' || i || '-' || hex(randomblob(40)) FROM n;"
    sleep 90
  ) | "$REAL_SQLITE3" "$db" > /dev/null 2>&1 &
  HOLD_PIDS+=("$!")
  for _ in $(seq 1 50); do [ -s "$db-wal" ] && break; sleep 0.2; done
}
unhold() {
  local p
  for p in "${HOLD_PIDS[@]}"; do
    pkill -P "$p" 2> /dev/null || true
    kill "$p" 2> /dev/null || true
  done
  HOLD_PIDS=()
}
trap 'unhold; rm -rf "$T"; rm -rf "${STAGE:-/nonexistent}"' EXIT
listing() { (cd "$1" && find . -printf '%p %u %m %s\n' | sort); }
unmask_obj() { tail -n +2 "$1" | tr 'N-ZA-Mn-za-m' 'A-Za-z'; }
export -f unmask_obj

# Helpers for the failure cases (run in this shell, so they see $rc, $T and $UPLOADS).
no_marker() { [ -z "$(find "$UPLOADS/apps/$1" -name "*.ok" 2> /dev/null | head -n 1)" ]; } # an object without its marker is incomplete by design
empty_dir() { [ -z "$(ls -A "$1")" ]; }
out_has() { grep -qF -- "$1" "$T/o"; }
job_refused() { # job_refused <job> <text in the output> [<directory that must stay empty>]
  [ "$rc" -eq 1 ] && out_has "$2" && no_marker "$1" && { [ -z "${3:-}" ] || empty_dir "$3"; }
}
STAGE="/dev/shm/home-lab-test-stage.$$"
if [ "$SQLITE_OK" = 1 ]; then
  mkdir -m 1777 "$STAGE"
  fresh
  mk_r19_apps
  hold_wal "$APPS/koffan/data/shopping.db"
  hold_wal "$APPS/n8n/data/database.sqlite"
  before="$(
    listing "$APPS/koffan/data"
    listing "$APPS/n8n/data"
  )"
  : > "$MOCK_LOG"
  backup MOCK_PG_ABSENT=1 HOME_LAB_STAGE_BASE="$STAGE"
  after="$(
    listing "$APPS/koffan/data"
    listing "$APPS/n8n/data"
  )"
  check "R19 success: exit 0 (koffan-db, n8n-db, n8n-files and couchdb; the other apps are not installed)" test "$rc" -eq 0
  for j in koffan-db n8n-db; do
    o="$(obj "$j" sqlite)"
    check "R19 $j: apps/$j/<UTC>.sqlite.age with its marker" bash -c 'test -n "$1" && test -f "$1.ok" && basename "$1" | grep -Eq "^[0-9]{8}T[0-9]{6}Z\.sqlite\.age$"' _ "$o"
    unmask_obj "$o" > "$T/restored-$j.db"
    check "R19 $j: the stored copy is a valid database with every row of the live WAL database, and passes integrity_check" bash -c '[ "$("$1" "$2" "SELECT count(*) FROM items;")" = 400 ] && [ "$("$1" "$2" "PRAGMA integrity_check;")" = ok ]' _ "$REAL_SQLITE3" "$T/restored-$j.db"
  done
  check "R19 sqlite: setpriv was asked to run sqlite3 as the owner of the database ($(id -u):$(id -g)) with --clear-groups, for the copy and for the integrity check, in both jobs" bash -c '[ "$(grep -cE "^SETPRIV --reuid=$1 --regid=$2 --clear-groups .*sqlite3 " "$3")" -ge 4 ]' _ "$(id -u)" "$(id -g)" "$MOCK_LOG"
  check "R19 sqlite: the staging directory is created and removed as the app uid too (no chown, no root-owned copy)" bash -c 'grep -q "^SETPRIV --reuid=$1 --regid=$2 --clear-groups mktemp -d $3/home-lab-backup\." "$4" && grep -q "^SETPRIV --reuid=$1 --regid=$2 --clear-groups rm -rf $3/home-lab-backup\." "$4"' _ "$(id -u)" "$(id -g)" "$STAGE" "$MOCK_LOG"
  check "R19 sqlite: the app directories are unchanged by the backup (same files, owners, modes, sizes: no new -wal or -shm)" test "$before" = "$after"
  check "R19 sqlite: nothing is left in the staging tmpfs, and no plaintext database copy exists anywhere else" bash -c '[ -z "$(ls -A "$1")" ] && ! grep -raq "SQLITE-PLAINTEXT-CANARY" "$2" --exclude-dir=apps --exclude-dir=mockbin --exclude="restored-*.db"' _ "$STAGE" "$T"
  check "R19 sqlite: every object went through age and holds no plaintext canary" bash -c 'for f in $(find "$1/apps" -name "*.age"); do grep -aq "PLAINTEXT-CANARY" "$f" && exit 1; done; exit 0' _ "$UPLOADS"
  check "R19: the Speedtest Tracker data is not backed up (no apps/speedtest object, its canary is in no upload)" bash -c '[ -z "$(find "$1" -path "*speedtest*" | head -1)" ] && ! grep -raq "SPEEDTEST-CANARY" "$1"' _ "$UPLOADS"
  unhold

  # off a tmpfs: refused, and nothing is written there
  NT="$(mktemp -d -p . .backup-test-nontmpfs.XXXXXX)"
  if [ "$(stat -f -c %T "$NT")" != tmpfs ]; then
    fresh
    mk_r19_apps
    hold_wal "$APPS/koffan/data/shopping.db"
    backup MOCK_PG_ABSENT=1 HOME_LAB_STAGE_BASE="$(cd "$NT" && pwd)"
    unhold
    check "R19 sqlite: a staging directory that is not a tmpfs is refused (exit 1, no marker for koffan-db), nothing written there" job_refused koffan-db "is not a tmpfs" "$NT"
  else
    printf 'SKIP  R19 off-tmpfs refusal (this file system is a tmpfs)\n'
  fi
  rm -rf "$NT"

  # a failed integrity check on the copy
  fresh
  mk_r19_apps
  hold_wal "$APPS/koffan/data/shopping.db"
  mkdir -p "$T/shim"
  cat > "$T/shim/sqlite3" << SHIM
#!/usr/bin/env bash
case "\$*" in *integrity_check*) echo "row 1 missing from index items_idx"; exit 0 ;; esac
exec "$REAL_SQLITE3" "\$@"
SHIM
  chmod +x "$T/shim/sqlite3"
  backup MOCK_PG_ABSENT=1 HOME_LAB_STAGE_BASE="$STAGE" PATH="$T/shim:$PATH"
  unhold
  check "R19 sqlite: a copy that fails PRAGMA integrity_check is not uploaded (exit 1, no marker for koffan-db), and the staging copy is removed" job_refused koffan-db "integrity_check on the copy failed" "$STAGE"

  # a copy larger than half of the available memory
  fresh
  mk_r19_apps
  hold_wal "$APPS/koffan/data/shopping.db"
  printf 'MemAvailable:         100 kB\n' > "$T/meminfo"
  backup MOCK_PG_ABSENT=1 HOME_LAB_STAGE_BASE="$STAGE" HOME_LAB_STAGE_FREE_BYTES=100
  unhold
  check "R19 sqlite: a database larger than half of the free staging space fails the job, and nothing is left in the staging tmpfs" job_refused koffan-db "half of the free space" "$STAGE"

  # a file that is not a database
  fresh
  mk_r19_apps
  printf 'this is not a database' > "$APPS/koffan/data/shopping.db"
  backup MOCK_PG_ABSENT=1 HOME_LAB_STAGE_BASE="$STAGE"
  check "R19 sqlite: a file that is not a database fails that job (exit 1, no marker, ONE alert naming koffan-db); the other jobs still upload" bash -c '[ "$1" = 1 ] && grep -q "koffan-db (the source (sqlite) failed" "$2" && [ -n "$(find "$3/apps/couchdb" -name "*.ok" | head -1)" ]' _ "$(published)" "$T/o" "$UPLOADS" && job_refused koffan-db "not a database"
fi


# N-1: a symlink swapped in by a compromised app is refused (sqlite database, couch data directory, tar source directory)
fresh
mk_r19_apps
ln -s "$T/outside.db" "$APPS/koffan/data/shopping.db"
printf 'OUTSIDE-SECRET' > "$T/outside.db"
mv "$APPS/couchdb/data" "$APPS/couchdb/realdata"
ln -s realdata "$APPS/couchdb/data"
mv "$APPS/n8n/data" "$APPS/n8n/realdata"
ln -s realdata "$APPS/n8n/data"
backup MOCK_PG_ABSENT=1 HOME_LAB_STAGE_BASE=/nonexistent-stage
check "N-1: a symlinked database, couchdb data directory and n8n tar source are all refused (exit 1, no marker for koffan-db, couchdb, n8n-files), the error says symbolic link" bash -c 'test "$1" -eq 1 && [ "$(grep -c "symbolic link" "$2")" -ge 3 ] && [ -z "$(find "$3/apps/koffan-db" "$3/apps/couchdb" "$3/apps/n8n-files" -name "*.ok" 2>/dev/null | head -1)" ]' _ "$rc" "$T/o" "$UPLOADS"
check "N-1: the file the link pointed at is in no upload" bash -c '! grep -raq "OUTSIDE-SECRET" "$1"' _ "$UPLOADS"
# n8n-files and couchdb need no sqlite3. Here the SQLite jobs cannot run (no staging base); that failure must not stop the others.
fresh
mk_r19_apps
printf 'x' > "$APPS/n8n/data/database.sqlite"
printf 'x' > "$APPS/n8n/data/database.sqlite-wal"
backup MOCK_PG_ABSENT=1 HOME_LAB_STAGE_BASE=/nonexistent-stage
check "R19: a failing SQLite job (no staging tmpfs) exits 1 with one alert, and n8n-files and couchdb are still uploaded" bash -c 'test "$1" -eq 1 && [ "$2" = 1 ] && grep -q "n8n-db (the source (sqlite) failed" "$3" && [ -n "$(find "$4/apps/n8n-files" -name "*.ok" | head -1)" ] && [ -n "$(find "$4/apps/couchdb" -name "*.ok" | head -1)" ]' _ "$rc" "$(published)" "$T/o" "$UPLOADS"
o="$(obj n8n-files tar)"
check "R19 n8n-files: the data directory is archived WITHOUT database.sqlite* and WITHOUT n8n's config file (it holds a copy of the encryption key, whose only copy is SSM), with binaryData" bash -c 'test -n "$1" && l="$(unmask_tar "$1")" && ! grep -qx "data/config" <<< "$l" && grep -qx "data/binaryData/file1" <<< "$l" && grep -qx "data/binaryData/nested/config" <<< "$l" && ! grep -q "database.sqlite" <<< "$l"' _ "$o"
o="$(obj couchdb tar)"
check "R19 couchdb: apps/couchdb/<UTC>.tar.age with its marker" bash -c 'test -n "$1" && test -f "$1.ok"' _ "$o"
check "R19 couchdb: the archive order is .shards, then shards, then the top-level *.couch files, then etc (CouchDB's documented order for a live copy)" bash -c 'l="$(unmask_tar "$1" | grep -v "/$")"; a="$(grep -n "^data/\.shards/" <<< "$l" | head -1 | cut -d: -f1)"; b="$(grep -n "^data/shards/" <<< "$l" | head -1 | cut -d: -f1)"; c="$(grep -n "^data/_dbs.couch$" <<< "$l" | cut -d: -f1)"; d="$(grep -n "^etc/docker.ini$" <<< "$l" | cut -d: -f1)"; [ -n "$a" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && grep -qx "data/_nodes.couch" <<< "$l"' _ "$o"
check "R19: no plaintext canary in any upload, no plaintext copy outside the app directories, nothing for Speedtest Tracker" bash -c '! grep -raq "COUCH-PLAINTEXT-CANARY\|N8N-FILES-PLAINTEXT-CANARY\|SPEEDTEST-CANARY" "$1" && ! grep -raq "COUCH-PLAINTEXT-CANARY" "$2" --exclude-dir=apps --exclude-dir=mockbin && [ -z "$(find "$1" -path "*speedtest*" | head -1)" ]' _ "$UPLOADS" "$T"

# ---------------------------------------------------------------- units
svc=scripts/systemd/home-lab-backup-apps.service
check "the service has the Authentik backup's hardening block (same sandbox) except for CapabilityBoundingSet and ReadWritePaths" bash -c 'diff <(sed -n "/^ProtectSystem=/,/^Nice=/p" "$1" | grep -vE "^(CapabilityBoundingSet|ReadWritePaths)=|^#") <(sed -n "/^ProtectSystem=/,/^Nice=/p" scripts/systemd/home-lab-backup-authentik.service | grep -vE "^(CapabilityBoundingSet|ReadWritePaths)=|^#")' _ "$svc"
check "R19: the bounding set adds exactly CAP_SETUID and CAP_SETGID to the Authentik backup's (setpriv for the SQLite jobs), nothing else" bash -c 'a="$(grep "^CapabilityBoundingSet=" scripts/systemd/home-lab-backup-authentik.service | cut -d= -f2)"; [ "$(grep "^CapabilityBoundingSet=" "$1" | cut -d= -f2)" = "$a CAP_SETUID CAP_SETGID" ]' _ "$svc"
check "R19: the only extra writable paths are the Koffan and n8n data directories (WAL files), and only those" bash -c 'grep -qxF "ReadWritePaths=-/apps/koffan/data -/apps/n8n/data" "$1" && [ "$(grep -c "^ReadWritePaths=" "$1")" = 1 ]' _ "$svc"
check "R19: ProcSubset=pid and ProtectProc=invisible are kept (the script must not read /proc/meminfo)" bash -c 'grep -q "^ProcSubset=pid$" "$1" && grep -q "^ProtectProc=invisible$" "$1" && ! grep -q "/proc/meminfo" scripts/lib/backup-streams.sh' _ "$svc"
check "R19: only the sqlite3 .backup call gets CAP_DAC_READ_SEARCH (ambient), nothing else in the library" bash -c '[ "$(grep -c "ambient-caps=+dac_read_search" scripts/lib/backup-streams.sh)" = 1 ] && grep -q "as_app_db sqlite3 -init" scripts/lib/backup-streams.sh && ! grep -q "as_app_db" <(grep -v "as_app_db()" scripts/lib/backup-streams.sh | grep -v "as_app_db sqlite3 -init /dev/null -cmd")' _
check "the service runs scripts/backup-apps.sh with OnFailure alerting, after the Authentik backup" bash -c 'grep -q "^ExecStart=@REPO_DIR@/scripts/backup-apps.sh$" "$1" && grep -q "^OnFailure=home-lab-alert-failure@%n.service$" "$1" && grep -q "^After=.*home-lab-backup-authentik.service" "$1"' _ "$svc"
check "the timer runs nightly at 03:15 (after the Authentik window), persistent" bash -c 'grep -q "^OnCalendar=\*-\*-\* 03:15:00$" "$1" && grep -q "^Persistent=true$" "$1"' _ scripts/systemd/home-lab-backup-apps.timer
check "units.sh, bootstrap.sh and preflight.sh know the new units" bash -c 'grep -q "home-lab-backup-apps.timer" scripts/lib/units.sh && grep -q "home-lab-backup-apps.timer" scripts/bootstrap.sh && grep -q "home-lab-backup-apps.timer" scripts/preflight.sh'

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll app backup checks passed\n'
