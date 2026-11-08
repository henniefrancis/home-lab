#!/usr/bin/env bash
# breakglass.sh - Pi, root: switch the Traefik dashboard break-glass login (Basic auth, no Authentik) on or off.
#
# Usage: sudo scripts/breakglass.sh on [MINUTES]   enable at https://bg-traefik.<domain>/ ; auto-off after MINUTES (default 60, max 480)
#        sudo scripts/breakglass.sh off            disable now
#        sudo scripts/breakglass.sh status         print enabled or disabled (exit 0 when disabled, 1 when enabled)
#
# It copies traefik/breakglass/bg-traefik.yml into Traefik's watched directory ($APPS_ROOT/traefik/dynamic; Traefik reloads
# it, no restart) and removes it again. Auto-off after the given minutes (a systemd timer), and the boot-time unit
# home-lab-breakglass-reset.service (installed by bootstrap.sh) deletes it at every reboot, so a forgotten break-glass can never
# become a standing MFA bypass (SEC-L3).
# Credentials: the Basic-auth line from SSM /home-lab/traefik/breakglass-htpasswd (runbook docs/runbooks/m4-authentik.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
APPS_ROOT="$(lab_env_get "$REPO_DIR/config/lab.env" APPS_ROOT /apps)"
BREAKGLASS_DIR="${BREAKGLASS_DIR:-$APPS_ROOT/traefik/dynamic}"
SRC="$REPO_DIR/traefik/breakglass/bg-traefik.yml"
DEST="$BREAKGLASS_DIR/bg-traefik.yml"

cmd="${1:-}"
case "$cmd" in
  -h | --help)
    sed -n '2,10p' "$0"
    exit 0
    ;;
  on | off | status) ;;
  *)
    sed -n '2,6p' "$0" >&2
    exit 2
    ;;
esac
minutes="${2:-60}"
[[ "$minutes" =~ ^[0-9]+$ ]] && [ "$minutes" -ge 1 ] && [ "$minutes" -le 480 ] || {
  echo "MINUTES must be 1-480" >&2
  exit 2
}
if [ "$cmd" != status ] && [ "${BREAKGLASS_NO_ROOT_CHECK:-0}" != 1 ]; then require_root "$@"; fi

case "$cmd" in
  on)
    [ -f "$SRC" ] || die "missing $SRC"
    install -d -m 0755 "$(dirname "$BREAKGLASS_DIR")" "$BREAKGLASS_DIR"
    install -m 0644 "$SRC" "$DEST"
    if [ "${BREAKGLASS_NO_TIMER:-0}" != 1 ] && command -v systemd-run > /dev/null 2>&1; then
      systemctl stop home-lab-breakglass-off.timer 2> /dev/null || true
      systemd-run --quiet --unit home-lab-breakglass-off --on-active="${minutes}m" /bin/rm -f "$DEST" ||
        warn "could not schedule the auto-off; run 'breakglass.sh off' yourself (a reboot also disables it)"
    fi
    warn "BREAK-GLASS ENABLED for $minutes minutes (auto-off). Disable earlier with: sudo scripts/breakglass.sh off"
    ;;
  off)
    rm -f "$DEST"
    systemctl stop home-lab-breakglass-off.timer 2> /dev/null || true
    echo "break-glass disabled"
    ;;
  status)
    if [ -e "$DEST" ]; then
      echo "enabled"
      exit 1
    fi
    echo "disabled"
    ;;
esac
