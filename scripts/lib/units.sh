#!/usr/bin/env bash
# shellcheck shell=bash
# The repo's systemd units and how they are installed. Source it; do not execute it. Needs common.sh.
# bootstrap.sh installs the rendered copies; preflight.sh and deploy.sh compare the installed copies with them, so a unit that changed
# in a release but was never installed (deploy.sh does not touch /etc/systemd) shows up as drift instead of a silent gap (QA-M-3).
# Override for tests: HOME_LAB_SYSTEMD_DIR.

LAB_UNITS=(
  home-lab-cert-expiry.service
  home-lab-cert-expiry.timer
  home-lab-alert-failure@.service
  home-lab-alert-test.service
  home-lab-alert-test.timer
  home-lab-breakglass-reset.service
)
SYSTEMD_DIR="${HOME_LAB_SYSTEMD_DIR:-/etc/systemd/system}"

# render_unit <repo_dir> <apps_root> <unit>: the unit file as it must be installed (paths rewritten to this checkout).
render_unit() {
  sed "s#@REPO_DIR@#$1#g; s#@APPS_ROOT@#$2#g" "$1/scripts/systemd/$3"
}

# unit_drift <repo_dir> <apps_root>: print one line per unit that is missing or differs from the repo copy. Prints nothing when current.
unit_drift() {
  local u
  for u in "${LAB_UNITS[@]}"; do
    if [ ! -f "$SYSTEMD_DIR/$u" ]; then
      echo "$u: not installed"
    elif ! render_unit "$1" "$2" "$u" | cmp -s - "$SYSTEMD_DIR/$u"; then
      echo "$u: differs from the repository copy"
    fi
  done
}
