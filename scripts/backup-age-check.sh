#!/usr/bin/env bash
# backup-age-check.sh - Pi: is the Authentik backup still being taken? (K5, SEC L-6). Run by `alert.sh check` (the daily timer), so a
# silent stop (a forgotten /etc/home-lab/restore-pending, a dead timer, a stopped container that nobody noticed) mails you; before this,
# only a hand-run preflight noticed. Same output and exit-code contract as cert-expiry.sh: lines start with [PASS], [WARN] or [FAIL];
# exit 0 = fine or not configured, 1 = warn, 2 = critical.
#
# Rules (alert keys carry the state, so an escalation from warn to critical mails again the same day, like the certificate checks):
#   - Not configured (no BACKUP_S3_BUCKET in aws.env): PASS, nothing to check (preflight already warns about the missing setup).
#   - /etc/home-lab/restore-pending exists: backups are skipped on purpose. Fine for 3 days (a restore takes an evening); WARN after 3 days,
#     FAIL after 7, with a message that says the sentinel is what is stopping them (age = the file's modification time).
#   - Otherwise the age of /var/lib/home-lab/backup-authentik.last (written only after a complete success): WARN after 2 days, FAIL after 7.
#   - No success recorded yet: the clock starts when this check FIRST saw the backup configured (it records that moment in
#     /var/lib/home-lab/backup-authentik.first-seen, written once, atomically). WARN 2 days after that, FAIL after 7. This does not depend
#     on when the timer was enabled or on file times that a restored card or a reflash would change.
#   - A success time in the future (a Pi with no RTC and a wrong clock) or garbage in the file counts as "no success recorded".
# Overrides for tests: HOME_LAB_ETC_DIR, HOME_LAB_STATE_DIR. Prints no secret.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ETC_DIR="${HOME_LAB_ETC_DIR:-/etc/home-lab}"
STATE_DIR="${HOME_LAB_STATE_DIR:-/var/lib/home-lab}"
WARN_S=$((2 * 86400))
CRIT_S=$((7 * 86400))
PENDING_WARN_S=$((3 * 86400))
now="$(date +%s)"

bucket="$(lab_env_get "$ETC_DIR/aws.env" BACKUP_S3_BUCKET)"
if [ -z "$bucket" ]; then
  echo "[PASS] backup-age: no backup configured (BACKUP_S3_BUCKET is not set), nothing to check"
  exit 0
fi

# verdict <age seconds> <warn limit> <message prefix> <what to do>
verdict() {
  local age="$1" warn="$2" what="$3" todo="$4" days=$(($1 / 86400))
  if [ "$age" -gt "$CRIT_S" ]; then
    echo "[FAIL] backup-age: $what ($days days). $todo"
    exit 2
  elif [ "$age" -gt "$warn" ]; then
    echo "[WARN] backup-age: $what ($days days). $todo"
    exit 1
  fi
}

pending="$ETC_DIR/restore-pending"
if [ -e "$pending" ]; then
  pm="$(stat -c %Y "$pending" 2> /dev/null || echo "$now")"
  [[ "$pm" =~ ^[0-9]+$ ]] && [ "$pm" -le "$now" ] || pm="$now"
  verdict $((now - pm)) "$PENDING_WARN_S" "$pending has existed for a while, so the nightly Authentik backups are being SKIPPED on purpose" \
    "If the restore is finished remove it (rm $pending); if not, finish it (docs/runbooks/authentik-backup.md section 6)."
  echo "[PASS] backup-age: restore in progress ($pending is less than 3 days old), backups are skipped on purpose"
  exit 0
fi

sf="$STATE_DIR/backup-authentik.last"
last="$(head -c 20 "$sf" 2> /dev/null | tr -d '\n' || true)"
if [[ "$last" =~ ^[0-9]{1,11}$ ]] && [ "$((10#$last))" -le "$now" ]; then
  last=$((10#$last))
  verdict $((now - last)) "$WARN_S" "the last successful Authentik backup is old" \
    "journalctl -u home-lab-backup-authentik.service; systemctl list-timers home-lab-backup-authentik.timer; docs/runbooks/authentik-backup.md."
  echo "[PASS] backup-age: the last successful Authentik backup was $(((now - last) / 3600)) hours ago"
  exit 0
fi

# No usable success time: start the clock the first time we see the backup configured and never move it.
fs="$STATE_DIR/backup-authentik.first-seen"
first="$(head -c 20 "$fs" 2> /dev/null | tr -d '\n' || true)"
if ! [[ "$first" =~ ^[0-9]{1,11}$ ]] || [ "$((10#$first))" -gt "$now" ]; then
  first="$now"
  if mkdir -p "$STATE_DIR" 2> /dev/null && printf '%s\n' "$now" > "$fs.new" 2> /dev/null && mv -f "$fs.new" "$fs" 2> /dev/null; then :; else
    echo "[WARN] backup-age: no successful Authentik backup is recorded and the first-seen time could not be written to $STATE_DIR"
    exit 1
  fi
fi
first=$((10#$first))
verdict $((now - first)) "$WARN_S" "no successful Authentik backup has been recorded since this check first saw backups configured" \
  "sudo systemctl start home-lab-backup-authentik.service, then docs/runbooks/authentik-backup.md."
echo "[PASS] backup-age: no backup recorded yet, but backups were configured less than 2 days ago"
exit 0
