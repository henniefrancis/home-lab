#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034 # the variables are read by bootstrap.sh and preflight.sh, which source this file
# Host hardening shared by bootstrap.sh (which applies it) and preflight.sh (which checks it). Source it; do not execute it.
# H1: automatic Debian security updates, no automatic reboot. H2: no LAN-facing desktop services on a server. H3: no stale
# cloud-init SSH drop-in that turns password logins on.
# Overrides for tests: HOME_LAB_APT_CONF_DIR, HOME_LAB_SSHD_CONF_DIR, HOME_LAB_RUN_DIR, HOME_LAB_UNATTENDED_BIN.

APT_CONF_DIR="${HOME_LAB_APT_CONF_DIR:-/etc/apt/apt.conf.d}"
AUTO_UPDATES_FILE="$APT_CONF_DIR/52home-lab-auto-upgrades"
SSHD_CONF_DIR="${HOME_LAB_SSHD_CONF_DIR:-/etc/ssh/sshd_config.d}"
CLOUD_INIT_SSHD_FILE="$SSHD_CONF_DIR/50-cloud-init.conf"
RUN_DIR="${HOME_LAB_RUN_DIR:-/run}"
UNATTENDED_BIN="${HOME_LAB_UNATTENDED_BIN:-unattended-upgrade}"

# H2: masked (not only disabled) because avahi is D-Bus activatable: a disabled avahi-daemon is started again by the first D-Bus call for it.
# Undo with: sudo systemctl unmask <unit> && sudo systemctl enable --now <unit>.
LAN_SERVICE_UNITS=(avahi-daemon.socket avahi-daemon.service)
# M12 (R17, owner decision 2026-11-10): Home Assistant uses the Pi's Bluetooth through BlueZ on the host (D-Bus), so Bluetooth is no longer
# masked; bootstrap.sh unmasks and enables these if an earlier version masked them. avahi stays masked (Home Assistant does its own mDNS).
BLUETOOTH_UNITS=(hciuart.service bluetooth.service)

# auto_updates_conf: the apt configuration bootstrap.sh installs. The origins stay the Debian defaults of the unattended-upgrades
# package (50unattended-upgrades: the Debian security archive), so Docker's and Raspberry Pi's own archives are NOT upgraded unattended
# (a Docker or kernel upgrade restarts containers or needs a reboot: do those by hand). 52- sorts after 20auto-upgrades, so these win.
auto_updates_conf() {
  cat << 'CONF'
// Managed by home-lab scripts/bootstrap.sh (H1): daily Debian security updates, never an automatic reboot.
// preflight.sh warns when a reboot is needed (/run/reboot-required). Remove this file to switch automatic updates off.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
CONF
}

# cloud_init_pw_only <file>: true when the file's only setting is "PasswordAuthentication yes" (what Raspberry Pi Imager's cloud-init
# writes when password SSH was ticked). Only then may bootstrap.sh delete it; a file with anything else in it is left for the owner.
cloud_init_pw_only() {
  local body
  [ -f "$1" ] || return 1
  body="$(sed -e 's/#.*//' -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' "$1" | grep -v '^$' || true)"
  [ "$(tr '[:upper:]' '[:lower:]' <<< "$body")" = "passwordauthentication yes" ]
}
