#!/usr/bin/env bash
# alert.sh - Pi, root: send alerts to the SNS topic home-lab-alerts (K4).
#
# Usage:
#   sudo scripts/alert.sh test                          send a test email now (no rate limit): proves the whole path
#   sudo scripts/alert.sh check                         run the certificate checks (cert-expiry.sh, served-cert-check.sh) and alert on any
#                                                       WARN or FAIL, at most one alert per check and state per day. Exit code = worst check
#                                                       (0 ok, 1 warn, 2 fail), so the systemd unit still shows as failed.
#   sudo scripts/alert.sh send <key> <subject> <message>   one rate-limited alert (OWNER USE: key lowercase letters, digits, hyphen)
#   sudo scripts/alert.sh unit-failed <unit>            the OnFailure= handler: alerts that a unit failed unless `check` already did
#
# Run daily by scripts/systemd/home-lab-cert-expiry.service; `test` runs monthly from home-lab-alert-test.timer (a heartbeat: a dead
# subscription is noticed by the mail that does not arrive). State: /var/lib/home-lab/alert-<key>.last (one epoch per key).
# Alert text never contains IPs, tailnet names, tokens or file contents. Topic and identity: scripts/lib/alert.sh.
# Runbook: docs/runbooks/alerting.md. Never prints credentials.
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/alert.sh
. "$SCRIPT_DIR/lib/alert.sh"

usage() {
  sed -n '2,15p' "$0"
}

host_label="$(hostname 2> /dev/null || echo pi)"
CHECK_UNIT="home-lab-cert-expiry.service"
# A service that is down is only reported when it stays down: a planned stop or a boot-time run must not mail (QA-L-5).
DOWN_GRACE="${HOME_LAB_DOWN_GRACE:-3600}"
BOOT_GRACE="${HOME_LAB_BOOT_GRACE:-600}"
UPTIME_FILE="${HOME_LAB_UPTIME_FILE:-/proc/uptime}"

unit_hash() { printf '%s' "$1" | sha256sum | cut -c1-16; }

uptime_seconds() {
  local u
  u="$(cut -d. -f1 "$UPTIME_FILE" 2> /dev/null || echo 999999)"
  [[ "$u" =~ ^[0-9]+$ ]] || u=999999
  printf '%s' "$((10#$u))"
}

# run_check <key> <label> <command...>: run one check and alert when it is not clean. The alert key carries the state (warn, crit,
# down, error), so an escalation inside one day still mails (QA-L-3). Updates WORST and ALERT_FAILED.
run_check() {
  local key="$1" label="$2" out rc=0 sev state down_file now first
  shift 2
  out="$("$@" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  down_file="$ALERT_STATE_DIR/.down-$key"
  if [ "$rc" -eq 0 ]; then
    rm -f "$down_file" 2> /dev/null || true
    return 0
  fi
  case "$rc" in
    1) state=warn sev=WARNING ;;
    2) state=crit sev=CRITICAL ;;
    3) state=down sev=CRITICAL ;;
    *) state=error sev=CRITICAL ;;
  esac
  # No [WARN] or [FAIL] line means the check itself broke (crash, usage error): say so, do not call it a certificate problem.
  if [ "$state" != error ] && ! printf '%s\n' "$out" | grep -qE '^\[(WARN|FAIL)\]'; then state=error sev=CRITICAL; fi
  if [ "$state" = error ]; then label="$label (the check could not run)"; fi
  if [ "$state" = down ]; then
    now="$(date +%s)"
    if [ "$(uptime_seconds)" -lt "$BOOT_GRACE" ]; then
      echo "note: $label: nothing answered, but the Pi booted less than $((BOOT_GRACE / 60)) minutes ago; not alerting yet"
      return 0
    fi
    mkdir -p "$ALERT_STATE_DIR" 2> /dev/null || true
    first="$(alert_last_sent "$down_file" "$now")"
    if [ -z "$first" ]; then
      printf '%s\n' "$now" > "$down_file" 2> /dev/null || true
      echo "note: $label: nothing answered; recorded, an alert follows if it is still down at the next run (planned stops do not mail)"
      return 0
    fi
    if [ $((now - first)) -lt "$DOWN_GRACE" ]; then
      echo "note: $label: still down, within the $((DOWN_GRACE / 60)) minute grace period"
      return 0
    fi
  fi
  # Alert failures must not hide the check result: the unit still fails with the check's own code.
  alert_send "$key-$state" "home-lab $sev: $label" "$(printf 'Host: %s\nCheck: %s\n%s\n\nWhat to do: docs/runbooks/alerting.md\n' "$host_label" "$label" "$out")" || ALERT_FAILED=1
  [ "$rc" -le 2 ] || rc=2
  [ "$rc" -le "$WORST" ] || WORST="$rc"
}

cmd_check() {
  local marker
  marker="$ALERT_STATE_DIR/.check-alerted-$(unit_hash "$CHECK_UNIT")"
  WORST=0
  ALERT_FAILED=0
  rm -f "$marker" 2> /dev/null || true
  run_check cert-expiry "Pi Roles Anywhere certificates" "$SCRIPT_DIR/cert-expiry.sh"
  run_check served-cert "certificate served by Traefik" "$SCRIPT_DIR/served-cert-check.sh"
  # K5, SEC L-6: a backup that silently stopped (a forgotten restore-pending file, a dead timer) mails too.
  run_check backup-age "Authentik backup age" "$SCRIPT_DIR/backup-age-check.sh"
  if [ "$WORST" -ne 0 ] && [ "$ALERT_FAILED" -eq 0 ]; then
    { mkdir -p "$ALERT_STATE_DIR" && : > "$marker"; } 2> /dev/null || true
  fi
  if [ "$ALERT_FAILED" -ne 0 ]; then
    warn "a check failed AND the alert could not be sent: fix alerting (docs/runbooks/alerting.md, sudo scripts/alert.sh test)"
  fi
  return "$WORST"
}

cmd_unit_failed() {
  local unit="${1:-}" marker now age key
  if ! [[ "$unit" =~ ^[A-Za-z0-9@._:\\-]{1,200}$ ]]; then
    # A name that cannot be used safely must not silence the alert: send a generic one (SEC-L-6).
    alert_send "unit-failed-unnamed" "home-lab CRITICAL: a unit failed" \
      "$(printf 'Host: %s\nA unit failed but its name could not be used safely.\nLook: systemctl --failed\nWhat to do: docs/runbooks/alerting.md\n' "$host_label")"
    return
  fi
  marker="$ALERT_STATE_DIR/.check-alerted-$(unit_hash "$unit")"
  # `check` exits non-zero on purpose when a certificate is bad and has already sent its own alert: do not mail twice.
  if [ -f "$marker" ]; then
    now="$(date +%s)"
    age=$((now - $(stat -c %Y "$marker" 2> /dev/null || echo 0)))
    if [ "$age" -ge 0 ] && [ "$age" -lt 600 ]; then
      echo "unit $unit failed after a check alert was already sent: no second mail"
      return 0
    fi
  fi
  key="unit-failed-$(unit_hash "$unit")"
  alert_send "$key" "home-lab CRITICAL: $unit failed" \
    "$(printf 'Host: %s\nUnit: %s failed.\nLook: systemctl status %s; journalctl -u %s -n 50\nWhat to do: docs/runbooks/alerting.md\n' "$host_label" "$unit" "$unit" "$unit")"
}

case "${1:-}" in
  test)
    alert_publish "home-lab TEST alert" "$(printf 'This is a test alert from %s at %s.\nIf you can read this email, the alert path works: Pi -> Roles Anywhere -> SNS -> email.\nA monthly test mail is normal. If one month passes without it, the subscription is dead (docs/runbooks/alerting.md).\n' "$host_label" "$(date -u +%Y-%m-%dT%H:%MZ)")"
    # Proof for preflight that a publish worked recently (it cannot prove the mail arrived: that is what you check in the inbox).
    { mkdir -p "$ALERT_STATE_DIR" && date +%s > "$ALERT_STATE_DIR/alert-test.published"; } 2> /dev/null || true
    echo "Check the inbox of the subscribed address (and its spam folder) within a minute."
    ;;
  check)
    cmd_check
    ;;
  send)
    [ $# -eq 4 ] || {
      usage >&2
      exit 2
    }
    alert_send "$2" "$3" "$4"
    ;;
  unit-failed)
    [ $# -eq 2 ] || {
      usage >&2
      exit 2
    }
    cmd_unit_failed "$2"
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
