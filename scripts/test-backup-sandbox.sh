#!/usr/bin/env bash
# test-backup-sandbox.sh - integration test of the SQLite backup path under the REAL privileges and the unit's OWN sandbox (R19, QA H1/H2/M1/M2).
# The mock-based scripts/test-backup-apps.sh cannot see these: it runs as an ordinary user, with a mocked setpriv and no /proc restrictions.
#
# What it does (root, systemd, real setpriv and sqlite3): builds /apps with the production layout (0700 root, an app-owned 0700 data directory,
# a live WAL database held open by a writer), then runs scripts/lib/backup-streams.sh sqlite_stream inside `systemd-run --wait --pipe --collect`
# with EVERY property of the hardening block of scripts/systemd/home-lab-backup-apps.service (ProtectSystem=strict ... Nice=), parsed from the
# unit file so the test cannot drift from it. Proves: the app uid reaches its database below a 0700 root /apps (H1), the free-space check works with
# ProcSubset=pid and ProtectProc=invisible (H2), /dev/shm is a usable tmpfs under PrivateDevices=true (M1), the copy is a valid database with every
# row of the live one, nothing is left behind, the app's directory is unchanged, and the failure paths (database owned by root, a staging directory
# that is not a tmpfs, a database larger than half of the free space) really fail.
# Usage: sudo scripts/test-backup-sandbox.sh   (CI: REQUIRE_SANDBOX=1 makes a missing prerequisite a failure instead of a skip)
# It creates and removes /apps/koffan and /opt/hl-sandbox-test; it refuses to run when /apps already exists.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
UNIT=scripts/systemd/home-lab-backup-apps.service
APP_UID=10008
APP_GID=10008

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
skip_or_fail() {
  if [ "${REQUIRE_SANDBOX:-0}" = 1 ]; then
    bad "prerequisite missing: $* (REQUIRE_SANDBOX=1: a skip is a failure)"
    exit 1
  fi
  printf 'SKIP  %s\n' "$*"
  exit 0
}
[ "$(id -u)" -eq 0 ] || skip_or_fail "not root"
[ -d /run/systemd/system ] || skip_or_fail "no systemd as init"
for t in systemd-run setpriv sqlite3 jq; do command -v "$t" > /dev/null || skip_or_fail "$t is missing"; done
[ ! -e /apps ] || {
  echo "ABORT: /apps exists; refusing to touch it" >&2
  exit 3
}

W=/opt/hl-sandbox-test
HOLD=""
cleanup() {
  [ -z "$HOLD" ] || { pkill -P "$HOLD" 2> /dev/null; kill "$HOLD" 2> /dev/null; } || true
  rm -rf /apps "$W" /dev/shm/home-lab-backup.* 2> /dev/null || true
}
trap cleanup EXIT

mkdir -p "$W"
cp scripts/lib/backup-streams.sh "$W/"
chmod 755 "$W" && chmod 644 "$W/backup-streams.sh"
mkdir -p /apps/koffan/data
chmod 0755 /apps   # the fixture writer (the app uid) must reach its directory; /apps becomes 0700 below, like production
chown -R "$APP_UID:$APP_GID" /apps/koffan
chmod 0700 /apps/koffan/data
DB=/apps/koffan/data/shopping.db
# a WAL database with 400 rows whose writer stays open, owned and written by the app uid
(
  printf '%s\n' "PRAGMA journal_mode=WAL;" "CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT);" \
    "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<400) INSERT INTO items(name) SELECT 'ROW-' || i || '-' || hex(randomblob(40)) FROM n;"
  sleep 120
) | setpriv --reuid="$APP_UID" --regid="$APP_GID" --clear-groups sqlite3 "$DB" > /dev/null 2>&1 &
HOLD=$!
for _ in $(seq 1 50); do [ -s "$DB-wal" ] && break; sleep 0.2; done
chmod 0700 /apps
check "fixture: /apps is 0700 root, the data directory 0700 and the live WAL database owned by the app uid" bash -c '[ "$(stat -c "%a %u" /apps)" = "700 0" ] && [ "$(stat -c "%a %u" /apps/koffan/data)" = "700 10008" ] && [ -s /apps/koffan/data/shopping.db-wal ]'
check "fixture: the app uid itself cannot reach its database (it cannot traverse /apps): the premise of H1" bash -c '! setpriv --reuid=10008 --regid=10008 --clear-groups test -r /apps/koffan/data/shopping.db'
listing() { (cd /apps/koffan/data && find . -printf '%p %u %m %s\n' | sort | grep -v 'shopping.db-wal\|shopping.db-shm\|shopping.db '); }
before="$(listing)"

# the unit's hardening block as systemd-run properties, parsed from the unit file
props=()
while IFS= read -r line; do
  case "$line" in '' | \#*) continue ;; esac
  props+=(-p "$line")
done < <(sed -n '/^ProtectSystem=/,/^Nice=/p' "$UNIT")
check "the unit's sandbox was parsed from the unit file (at least 20 properties, including ProtectSystem, PrivateDevices, ProcSubset, ProtectProc and the capability bounding set)" bash -c '[ "$1" -ge 40 ] && grep -q ProcSubset=pid <<< "$2" && grep -q PrivateDevices=true <<< "$2" && grep -q ProtectProc=invisible <<< "$2" && grep -q CapabilityBoundingSet= <<< "$2"' _ "${#props[@]}" "${props[*]}"

run_unit() { # run_unit <stage base> <db dir under /apps> <db relative path> [env assignments]: the stream on stdout, errors on stderr
  local base="$1" dir="$2" rel="$3"
  shift 3
  systemd-run --wait --pipe --collect --quiet "${props[@]}" --setenv=APPS_ROOT=/apps "--setenv=STAGE_BASE=$base" "$@" \
    /bin/bash -c ". $W/backup-streams.sh; sqlite_stream $dir $rel"
}

run_unit /dev/shm koffan data/shopping.db > "$W/copy.db" 2> "$W/err.txt"
rc=$?
check "H1/H2/M1: under the unit's own sandbox the backup stream succeeds as root-with-setpriv (exit 0) [rc=$rc: $(head -c 200 "$W/err.txt" | tr '\n' ' ')]" test "$rc" -eq 0
check "the stream is a valid database with every row of the live WAL database, and passes integrity_check" bash -c '[ "$(sqlite3 "$1" "SELECT count(*) FROM items;")" = 400 ] && [ "$(sqlite3 "$1" "PRAGMA integrity_check;")" = ok ]' _ "$W/copy.db"
check "M1: /dev/shm inside the sandbox is a tmpfs and usable by the app uid (the job's own check passed, no 'not a tmpfs' message)" bash -c '! grep -q "not a tmpfs" "$1"' _ "$W/err.txt"
check "nothing is left in /dev/shm and the app's data directory is unchanged (no root-owned -wal or -shm, same files, owners, modes)" bash -c '[ -z "$(ls -A /dev/shm | grep home-lab-backup)" ] && [ "$1" = "$2" ]' _ "$before" "$(listing)"
check "no file in /apps is owned by root (sqlite3 never ran as root next to the live database)" bash -c '[ -z "$(find /apps/koffan -user 0)" ]'

# the same call WITHOUT the ambient capability must fail: this is the H1 defect, so the test proves it is what the capability fixes
sed 's/ --inh-caps=+dac_read_search --ambient-caps=+dac_read_search//' "$W/backup-streams.sh" > "$W/no-cap.sh"
chmod 644 "$W/no-cap.sh"
systemd-run --wait --pipe --collect --quiet "${props[@]}" --setenv=APPS_ROOT=/apps --setenv=STAGE_BASE=/dev/shm \
  /bin/bash -c ". $W/no-cap.sh; sqlite_stream koffan data/shopping.db" > /dev/null 2> "$W/err2.txt"
rc2=$?
check "H1 proof: without CAP_DAC_READ_SEARCH the same stream fails ('unable to open database file') [rc=$rc2]" bash -c '[ "$1" -ne 0 ] && grep -qi "unable to open\|backup failed" "$2"' _ "$rc2" "$W/err2.txt"

# failure paths
run_unit "$W" koffan data/shopping.db > /dev/null 2> "$W/err3.txt"
rc3=$?
check "a staging directory that is not a tmpfs is refused under the sandbox [rc=$rc3]" bash -c '[ "$1" -ne 0 ] && grep -q "is not a tmpfs" "$2"' _ "$rc3" "$W/err3.txt"
run_unit /dev/shm koffan data/shopping.db --setenv=HOME_LAB_STAGE_FREE_BYTES=100 > /dev/null 2> "$W/err4.txt"
rc4=$?
check "a database larger than half of the free staging space is refused [rc=$rc4]" bash -c '[ "$1" -ne 0 ] && grep -q "half of the free space" "$2"' _ "$rc4" "$W/err4.txt"
mkdir -p /apps/rootowned/data
printf 'x' > /apps/rootowned/data/x.db
run_unit /dev/shm rootowned data/x.db > /dev/null 2> "$W/err5.txt"
rc5=$?
check "a database owned by root is refused (sqlite3 is never run as root next to a live database) [rc=$rc5]" bash -c '[ "$1" -ne 0 ] && grep -q "refusing to run sqlite3 as root" "$2"' _ "$rc5" "$W/err5.txt"

mkdir -p /apps/linked/data
printf 'ROOT-ONLY-SECRET' > "$W/secret.txt"
ln -s "$W/secret.txt" /apps/linked/data/x.db
chown -h "$APP_UID:$APP_GID" /apps/linked/data/x.db
run_unit /dev/shm linked data/x.db > "$W/out6.bin" 2> "$W/err6.txt"
rc6=$?
check "N-1: a database replaced by a symlink (owned by the app uid) is refused under the sandbox and its target is not read [rc=$rc6]" bash -c '[ "$1" -ne 0 ] && grep -q "symbolic link" "$2" && ! grep -q ROOT-ONLY-SECRET "$3"' _ "$rc6" "$W/err6.txt" "$W/out6.bin"
rm -f "$W/secret.txt"
if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll backup sandbox checks passed\n'
