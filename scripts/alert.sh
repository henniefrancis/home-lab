#!/usr/bin/env bash
# alert.sh - Pi, root: send alerts to the SNS topic home-lab-alerts (K4).
#
# Usage:
#   sudo scripts/alert.sh test                          send a test email now (no rate limit): proves the whole path
#   sudo scripts/alert.sh check                         run the certificate checks (cert-expiry.sh, served-cert-check.sh) and alert on any
#                                                       WARN or FAIL, at most one alert per check per day. Exit code = worst check
#                                                       (0 ok, 1 warn, 2 fail), so the systemd unit still shows as failed.
#   sudo scripts/alert.sh send <key> <subject> <message>   one rate-limited alert (key: lowercase letters, digits, hyphen)
#   sudo scripts/alert.sh unit-failed <unit>            the OnFailure= handler: alerts that a unit failed unless `check` already did
#
# Run daily by scripts/systemd/home-lab-cert-expiry.service. State: /var/lib/home-lab/alert-<key>.last (one epoch number per key).
# Topic and identity: scripts/lib/alert.sh. Runbook: docs/runbooks/alerting.md. Never prints credentials.
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/alert.sh
. "$SCRIPT_DIR/lib/alert.sh"

usage() {
  sed -n '2,13p' "$0"
}

host_label="$(hostname 2> /dev/null || echo pi)"

# run_check <key> <label> <command...>: run one check, alert when it is not clean. Sets CHECK_RC (0, 1, 2).
run_check() {
  local key="$1" label="$2" out rc=0
  shift 2
  out="$("$@" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 3 ] && rc=2
  [ "$rc" -le 2 ] || rc=2
  if [ "$rc" -ne 0 ]; then
    local sev=WARNING
    [ "$rc" -eq 2 ] && sev=CRITICAL
    # Alert failures must not hide the check result: the unit still fails with the check's own code.
    alert_send "$key" "home-lab $sev: $label" "$(printf 'Host: %s\nCheck: %s\n%s\n\nWhat to do: docs/runbooks/alerting.md\n' "$host_label" "$label" "$out")" || ALERT_FAILED=1
  fi
  [ "$rc" -le "$WORST" ] || WORST="$rc"
}

cmd_check() {
  WORST=0
  ALERT_FAILED=0
  rm -f "$ALERT_STATE_DIR/.check-alerted" 2> /dev/null || true
  run_check cert-expiry "Pi Roles Anywhere certificates" "$SCRIPT_DIR/cert-expiry.sh"
  run_check served-cert "certificate served by Traefik" "$SCRIPT_DIR/served-cert-check.sh"
  if [ "$WORST" -ne 0 ] && [ "$ALERT_FAILED" -eq 0 ]; then
    mkdir -p "$ALERT_STATE_DIR" 2> /dev/null && : > "$ALERT_STATE_DIR/.check-alerted" || true
  fi
  if [ "$ALERT_FAILED" -ne 0 ]; then
    warn "a check failed AND the alert could not be sent: fix alerting (docs/runbooks/alerting.md, sudo scripts/alert.sh test)"
  fi
  return "$WORST"
}

cmd_unit_failed() {
  local unit="${1:-}" marker="$ALERT_STATE_DIR/.check-alerted" now age
  [[ "$unit" =~ ^[A-Za-z0-9@._-]{1,100}$ ]] || die "unit-failed needs a unit name"
  # `check` exits non-zero on purpose when a certificate is bad and has already sent its own alert: do not mail twice.
  if [ -f "$marker" ]; then
    now="$(date +%s)"
    age=$((now - $(stat -c %Y "$marker" 2> /dev/null || echo 0)))
    if [ "$age" -lt 600 ]; then
      echo "unit $unit failed after a check alert was already sent: no second mail"
      return 0
    fi
  fi
  alert_send "unit-failed-$(printf '%s' "$unit" | tr -c 'a-z0-9\n' '-' | cut -c1-24)" "home-lab CRITICAL: $unit failed" \
    "$(printf 'Host: %s\nUnit: %s failed.\nLook: systemctl status %s; journalctl -u %s -n 50\nWhat to do: docs/runbooks/alerting.md\n' "$host_label" "$unit" "$unit" "$unit")"
}

case "${1:-}" in
  test)
    alert_publish "home-lab TEST alert" "$(printf 'This is a test alert from %s at %s.\nIf you can read this email, the alert path works: Pi -> Roles Anywhere -> SNS -> email.\n' "$host_label" "$(date -u +%Y-%m-%dT%H:%MZ)")"
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
