#!/usr/bin/env bash
# bootstrap.sh - Pi, root, idempotent: prepare the host for the home lab. Contains and writes no secrets.
#
# Usage: sudo scripts/bootstrap.sh [--upgrade-aws]
#
# What it does (safe to re-run; each step skips when already satisfied):
#   1. Refuses to continue if scripts/preflight.sh reports a FAIL.
#   2. apt: curl, unzip, gnupg, jq, openssl, ca-certificates, git, openssh-client (ssh-keygen: commit signature check), util-linux
#      (flock), age (client-side encryption of the Authentik backup, K5), unattended-upgrades (H1) - only the missing ones. age comes
#      from Debian's own package (trixie: 1.2.x, apt's signature check is the integrity control); nothing is pinned beyond what apt installs.
#   3. Directory layout: $APPS_ROOT/{traefik,authentik,homepage,tailscale,pihole,secrets}, /etc/home-lab, /etc/home-lab/pki; the Authentik
#      data and Postgres directories owned by the service uids from config/lab.env (never the login user).
#   4. Docker networks (plan 6.1): proxy, authentik-auth (Traefik <-> Authentik forward auth only), authentik-internal (internal).
#      No docker socket proxy exists any more (SEC-H2).
#   5. Loads and persists the tun kernel module and sets net.ipv4.conf.all.src_valid_mark=1 on the host (Tailscale; the
#      container cannot write /proc/sys, so this is done here instead of adding capabilities). Host hardening (scripts/lib/host.sh):
#      key-only SSH (A4), daily Debian security updates with no automatic reboot (H1), avahi masked (H2; Bluetooth stays on for Home Assistant, M12), and a cloud-init
#      drop-in that only turns SSH passwords on is removed (H3).
#   6. Installs AWS CLI v2 (aarch64): official installer, GPG signature verified against the AWS CLI team key.
#   7. Installs aws_signing_helper at the pinned version: SHA256 verified against the AWS user guide value
#      (scripts/lib/pins.sh cites the source), installed 0555 root.
# Plan: docs/plan/phase-1-traefik.md section 6.10. Runbook: docs/runbooks/m2-pi-setup.md.
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/units.sh
. "$SCRIPT_DIR/lib/units.sh"
# shellcheck source=lib/pins.sh
. "$SCRIPT_DIR/lib/pins.sh"
# shellcheck source=lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"

UPGRADE_AWS=0
for a in "$@"; do
  case "$a" in
    --upgrade-aws) UPGRADE_AWS=1 ;;
    -h | --help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $a" ;;
  esac
done
require_root "$@"

APPS_ROOT="$(lab_env_get "$LAB_ENV" APPS_ROOT /apps)"
PROXY_SUBNET="$(lab_env_get "$LAB_ENV" PROXY_SUBNET 172.30.0.0/24)"
AUTH_SUBNET="$(lab_env_get "$LAB_ENV" AUTHENTIK_AUTH_SUBNET 172.30.1.0/24)"
OIDC_SUBNET="$(lab_env_get "$LAB_ENV" OIDC_SUBNET 172.30.2.0/24)"
N8N_SUBNET="$(lab_env_get "$LAB_ENV" N8N_SUBNET 172.30.3.0/24)"
ETC_DIR=/etc/home-lab

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

step "1/7 Preflight (system checks)"
"$SCRIPT_DIR/preflight.sh" || die "preflight reported FAIL; fix the findings and re-run bootstrap.sh"

step "2/7 Required packages"
missing=()
for pair in curl:curl unzip:unzip gpg:gnupg jq:jq openssl:openssl git:git ssh-keygen:openssh-client flock:util-linux age:age sqlite3:sqlite3 setpriv:util-linux unattended-upgrade:unattended-upgrades; do
  command -v "${pair%%:*}" > /dev/null 2>&1 || missing+=("${pair##*:}")
done
if [ "${#missing[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends ca-certificates "${missing[@]}"
else
  info "all present"
fi

step "3/7 Directory layout"
# 0700 like fetch-secrets.sh sets it on every deploy: only root (and the Docker daemon) traverses $APPS_ROOT. Containers reach their
# directories through bind mounts, never through this path, so nothing needs to cross it as another user.
install -d -m 0700 -o root -g root "$APPS_ROOT"
for d in traefik authentik homepage tailscale pihole linkwarden netdata portainer homeassistant koffan speedtest couchdb n8n; do
  install -d -m 0755 -o root -g root "$APPS_ROOT/$d"
done
install -d -m 0700 -o root -g root "$APPS_ROOT/tailscale/state"
# Traefik runs as TRAEFIK_UID:TRAEFIK_GID (not root, SEC-L9) and owns its ACME storage; a directory created by an earlier
# version (root-owned) is re-owned here, contents included.
TR_UID="$(lab_env_get "$LAB_ENV" TRAEFIK_UID 10004)"
TR_GID="$(lab_env_get "$LAB_ENV" TRAEFIK_GID 10004)"
# Authentik (M4, F02): service ids from config/lab.env, never the login user (1000). The server/worker own their data directory;
# PostgreSQL owns its data directory (its image-native 70:70). Both 0700; /apps/authentik itself stays root 0755.
AK_UID="$(lab_env_get "$LAB_ENV" AUTHENTIK_UID 10002)"
AK_GID="$(lab_env_get "$LAB_ENV" AUTHENTIK_GID 10002)"
PG_UID="$(lab_env_get "$LAB_ENV" AUTHENTIK_PG_UID 70)"
PG_GID="$(lab_env_get "$LAB_ENV" AUTHENTIK_PG_GID 70)"
# Homepage (M5) runs as HOMEPAGE_UID:HOMEPAGE_GID with a read-only root file system and its config mounted read-only from the
# checkout: it owns no directory under $APPS_ROOT, so nothing is created for it beyond $APPS_ROOT/homepage (root 0755, above).
HP_UID="$(lab_env_get "$LAB_ENV" HOMEPAGE_UID 10003)"
HP_GID="$(lab_env_get "$LAB_ENV" HOMEPAGE_GID 10003)"
# Pi-hole (M8): FTL runs as PIHOLE_UID and owns its configuration and databases (the image default 1000 is overridden).
PH_UID="$(lab_env_get "$LAB_ENV" PIHOLE_UID 10006)"
PH_GID="$(lab_env_get "$LAB_ENV" PIHOLE_GID 10006)"
# Linkwarden (M9): the app and its Meilisearch run as LINKWARDEN_UID; its PostgreSQL as the postgres image user (AUTHENTIK_PG_UID, 70).
LW_UID="$(lab_env_get "$LAB_ENV" LINKWARDEN_UID 10007)"
LW_GID="$(lab_env_get "$LAB_ENV" LINKWARDEN_GID 10007)"
# R19 apps: Koffan (SQLite), Speedtest Tracker (PUID after its root init, ADR-018), n8n (SQLite) and CouchDB each own their data directory.
KF_UID="$(lab_env_get "$LAB_ENV" KOFFAN_UID 10008)"
KF_GID="$(lab_env_get "$LAB_ENV" KOFFAN_GID 10008)"
ST_UID="$(lab_env_get "$LAB_ENV" SPEEDTEST_UID 10009)"
ST_GID="$(lab_env_get "$LAB_ENV" SPEEDTEST_GID 10009)"
N8_UID="$(lab_env_get "$LAB_ENV" N8N_UID 10010)"
N8_GID="$(lab_env_get "$LAB_ENV" N8N_GID 10010)"
CD_UID="$(lab_env_get "$LAB_ENV" COUCHDB_UID 10011)"
CD_GID="$(lab_env_get "$LAB_ENV" COUCHDB_GID 10011)"
for id in "$AK_UID" "$AK_GID" "$PG_UID" "$PG_GID" "$HP_UID" "$HP_GID" "$TR_UID" "$TR_GID" "$PH_UID" "$PH_GID" "$LW_UID" "$LW_GID" \
  "$KF_UID" "$KF_GID" "$ST_UID" "$ST_GID" "$N8_UID" "$N8_GID" "$CD_UID" "$CD_GID"; do
  [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -ne 0 ] && [ "$id" -ne 1000 ] || die "service uid/gid '$id' in $LAB_ENV must be numeric, not 0 and not 1000 (the login user)"
done
# Traefik's watched dynamic-configuration directory: root-owned copy of traefik/dynamic, filled by deploy.sh.
install -d -m 0755 -o root -g root "$APPS_ROOT/traefik/dynamic"
install -d -m 0700 -o "$TR_UID" -g "$TR_GID" "$APPS_ROOT/traefik/letsencrypt"
chown -R "$TR_UID:$TR_GID" "$APPS_ROOT/traefik/letsencrypt"
install -d -m 0700 -o "$AK_UID" -g "$AK_GID" "$APPS_ROOT/authentik/data"
install -d -m 0700 -o "$PG_UID" -g "$PG_GID" "$APPS_ROOT/authentik/postgres"
# 0755, not 0700: the image's pihole-FTL-prestart.sh resets every directory under /etc/pihole to 0755 (files 0640) on each start.
# Nothing below is reachable by other users anyway: $APPS_ROOT itself is root 0700.
install -d -m 0755 -o "$PH_UID" -g "$PH_GID" "$APPS_ROOT/pihole/etc-pihole"
install -d -m 0700 -o "$LW_UID" -g "$LW_GID" "$APPS_ROOT/linkwarden/data" "$APPS_ROOT/linkwarden/meili"
install -d -m 0700 -o "$PG_UID" -g "$PG_GID" "$APPS_ROOT/linkwarden/postgres"
# R19 apps, all 0700 and owned by the service uid: Koffan's database, Speedtest Tracker's /config, n8n's user folder (its database, and the
# key it generates when none is given) and CouchDB's data and runtime configuration (local.d: the hashed admin password is written there).
install -d -m 0700 -o "$KF_UID" -g "$KF_GID" "$APPS_ROOT/koffan/data"
install -d -m 0700 -o "$ST_UID" -g "$ST_GID" "$APPS_ROOT/speedtest/config"
install -d -m 0700 -o "$N8_UID" -g "$N8_GID" "$APPS_ROOT/n8n/data"
install -d -m 0700 -o "$CD_UID" -g "$CD_GID" "$APPS_ROOT/couchdb/data" "$APPS_ROOT/couchdb/etc"
# Netdata (M10) starts as root and hands these to its own netdata user itself (the official image does not support `user:`).
install -d -m 0755 -o root -g root "$APPS_ROOT/netdata/lib" "$APPS_ROOT/netdata/cache"
# Portainer (M11) runs as root inside its container (ADR-017) and keeps its database here.
install -d -m 0700 -o root -g root "$APPS_ROOT/portainer/data"
# Home Assistant (M12) runs as root inside its container. Its starting configuration is copied ONCE, only into an empty config directory:
# afterwards the files belong to Home Assistant and the owner and are never overwritten. .storage/http holds the HTTP server settings as
# the STABLE setting (listen only on the proxy gateway): see homeassistant/compose.yaml for why it is not an http: block in YAML.
install -d -m 0700 -o root -g root "$APPS_ROOT/homeassistant/config"
if [ ! -e "$APPS_ROOT/homeassistant/config/configuration.yaml" ] && [ ! -e "$APPS_ROOT/homeassistant/config/.storage/http" ]; then
  install -d -m 0700 -o root -g root "$APPS_ROOT/homeassistant/config/.storage"
  install -m 0644 -o root -g root "$REPO_DIR/homeassistant/seed/configuration.yaml" "$APPS_ROOT/homeassistant/config/configuration.yaml"
  install -m 0600 -o root -g root "$REPO_DIR/homeassistant/seed/.storage/http" "$APPS_ROOT/homeassistant/config/.storage/http"
  info "seeded $APPS_ROOT/homeassistant/config (first run: configuration.yaml and the HTTP server settings)"
fi
# fetch-secrets.sh publishes releases under .secrets.d and points $APPS_ROOT/secrets at the current one (atomic swap).
install -d -m 0700 -o root -g root "$APPS_ROOT/.secrets.d"
if [ ! -L "$APPS_ROOT/secrets" ]; then
  install -d -m 0700 -o root -g root "$APPS_ROOT/secrets"
fi
install -d -m 0700 -o root -g root "$ETC_DIR" "$ETC_DIR/pki"
info "ok: $APPS_ROOT and $ETC_DIR created with the plan's owners and modes"

step "4/7 Docker networks"
ensure_network() { # ensure_network <name> [extra docker network create args...]
  local name="$1"
  shift
  if docker network inspect "$name" > /dev/null 2>&1; then
    info "network $name exists"
  else
    docker network create --driver bridge "$@" "$name" > /dev/null
    info "network $name created"
  fi
}
ensure_network proxy --subnet "$PROXY_SUBNET"
have_subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' proxy)"
case " $have_subnet " in
  *" $PROXY_SUBNET "*) ;;
  *) warn "network proxy exists with subnet(s) '$have_subnet', not $PROXY_SUBNET; Traefik trusted-proxy settings assume PROXY_SUBNET" ;;
esac
ensure_network authentik-auth --subnet "$AUTH_SUBNET"
if docker network inspect socket-proxy > /dev/null 2>&1; then
  warn "the old docker network socket-proxy still exists; nothing uses it any more (SEC-H2): docker network rm socket-proxy"
fi
ensure_network authentik-internal --internal
# M9: the OIDC back-channel (Traefik answers as auth.<domain> there; only the Authentik router allows the subnet), and Linkwarden's
# own internal network (the app, its PostgreSQL and Meilisearch; no route out).
ensure_network oidc --subnet "$OIDC_SUBNET"
ensure_network linkwarden-internal --internal
# R19: n8n has its own (not internal) network, joined only by Traefik and n8n: no path to the other apps, but internet egress.
ensure_network n8n --subnet "$N8N_SUBNET"
have_n8n="$(docker network inspect -f "{{range .IPAM.Config}}{{.Subnet}} {{end}}" n8n)"
case " $have_n8n " in
  *" $N8N_SUBNET "*) ;;
  *) warn "network n8n exists with subnet(s) $have_n8n, not $N8N_SUBNET (config/lab.env)" ;;
esac

step "5/7 tun kernel module and Tailscale sysctl"
if modprobe tun 2> /dev/null; then
  printf 'tun\n' > /etc/modules-load.d/home-lab.conf
  info "tun loaded and persisted in /etc/modules-load.d/home-lab.conf"
else
  warn "could not load the tun module; Tailscale needs /dev/net/tun"
fi
# Tailscale marks its packets and wants src_valid_mark=1 (reverse-path filtering with fwmark routing). The container
# runs with host networking but a read-only /proc/sys, so it logs "failed to enable src_valid_mark"; the host sets it.
SYSCTL_FILE=/etc/sysctl.d/99-home-lab.conf
SYSCTL_WANT=$'# Managed by home-lab scripts/bootstrap.sh\nnet.ipv4.conf.all.src_valid_mark = 1\n'
if [ "$(cat "$SYSCTL_FILE" 2> /dev/null || true)" != "${SYSCTL_WANT%$'\n'}" ]; then
  printf '%s' "$SYSCTL_WANT" > "$SYSCTL_FILE"
  chmod 0644 "$SYSCTL_FILE"
  info "wrote $SYSCTL_FILE"
fi
if sysctl -q -p "$SYSCTL_FILE" > /dev/null 2>&1; then
  info "net.ipv4.conf.all.src_valid_mark=$(sysctl -n net.ipv4.conf.all.src_valid_mark) (persisted)"
else
  warn "could not apply $SYSCTL_FILE; Tailscale may log 'failed to enable src_valid_mark' (harmless once the value is 1)"
fi

# A4: key-only SSH, even while SSH is off (Raspberry Pi Connect is the access path), so turning SSH on later never opens password logins.
# sshd keeps the FIRST value it reads and reads sshd_config.d/*.conf in name order, so the 00- prefix wins over the distribution's files.
if [ -f /etc/ssh/sshd_config ]; then
  SSHD_FILE=/etc/ssh/sshd_config.d/00-home-lab-keys-only.conf
  SSHD_WANT=$'# Managed by home-lab scripts/bootstrap.sh (A4): key-only SSH.\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n'
  if [ "$(cat "$SSHD_FILE" 2> /dev/null || true)" != "${SSHD_WANT%$'\n'}" ]; then
    install -d -m 0755 /etc/ssh/sshd_config.d
    printf '%s' "$SSHD_WANT" > "$SSHD_FILE"
    chmod 0644 "$SSHD_FILE"
    if command -v sshd > /dev/null 2>&1 && ! sshd -t > /dev/null 2>&1; then
      rm -f "$SSHD_FILE"
      warn "sshd rejected $SSHD_FILE, so it was removed and SSH is unchanged"
    else
      info "wrote $SSHD_FILE (key-only SSH)"
      if systemctl is-active --quiet ssh 2> /dev/null; then systemctl reload ssh 2> /dev/null || warn "could not reload ssh"; fi
    fi
  fi
  # H3: Raspberry Pi Imager's cloud-init writes 50-cloud-init.conf with "PasswordAuthentication yes" when password SSH was ticked. The
  # 00- file above already wins, but the stale line misleads whoever reads the directory. Removed only when that is its sole setting.
  if cloud_init_pw_only "$CLOUD_INIT_SSHD_FILE"; then
    rm -f "$CLOUD_INIT_SSHD_FILE"
    info "removed $CLOUD_INIT_SSHD_FILE (its only setting was PasswordAuthentication yes)"
  elif [ -f "$CLOUD_INIT_SSHD_FILE" ]; then
    info "left $CLOUD_INIT_SSHD_FILE in place: it holds more than the password setting (the 00- file still wins)"
  fi
fi

# H1: daily Debian security updates (unattended-upgrades), no automatic reboot; preflight.sh warns when a reboot is pending.
AUTO_WANT="$(auto_updates_conf)"
if [ "$(cat "$AUTO_UPDATES_FILE" 2> /dev/null || true)" != "$AUTO_WANT" ]; then
  install -d -m 0755 "$APT_CONF_DIR"
  printf '%s\n' "$AUTO_WANT" > "$AUTO_UPDATES_FILE"
  chmod 0644 "$AUTO_UPDATES_FILE"
  info "wrote $AUTO_UPDATES_FILE (daily security updates, no automatic reboot)"
fi
if systemctl enable --now apt-daily.timer apt-daily-upgrade.timer > /dev/null 2>&1; then
  info "apt-daily.timer and apt-daily-upgrade.timer enabled (they run unattended-upgrade)"
else
  warn "could not enable apt-daily.timer and apt-daily-upgrade.timer: security updates will not install on their own"
fi

# H2: no mDNS on a server: fewer listeners on the LAN. Masked because avahi is D-Bus activatable (lib/host.sh).
masked=()
for u in "${LAN_SERVICE_UNITS[@]}"; do
  systemctl cat "$u" > /dev/null 2>&1 || continue
  [ "$(systemctl is-enabled "$u" 2> /dev/null || true)" = masked ] && continue
  if systemctl disable --now "$u" > /dev/null 2>&1 && systemctl mask "$u" > /dev/null 2>&1; then
    masked+=("$u")
  else
    warn "could not stop and mask $u"
  fi
done
[ "${#masked[@]}" -eq 0 ] || info "stopped and masked: ${masked[*]} (undo: systemctl unmask <unit> && systemctl enable --now <unit>)"
# M12: Home Assistant needs the Pi's Bluetooth (BlueZ on the host, reached over D-Bus). An earlier bootstrap masked it (H2 before M12):
# unmask and start it again. A unit that does not exist (no Bluetooth hardware or package) is skipped.
for u in "${BLUETOOTH_UNITS[@]}"; do
  systemctl cat "$u" > /dev/null 2>&1 || [ "$(systemctl is-enabled "$u" 2> /dev/null || true)" = masked ] || continue
  if [ "$(systemctl is-enabled "$u" 2> /dev/null || true)" = masked ]; then
    if systemctl unmask "$u" > /dev/null 2>&1 && systemctl enable --now "$u" > /dev/null 2>&1; then
      info "unmasked and started $u (Home Assistant Bluetooth, M12)"
    else
      warn "could not unmask and start $u: Home Assistant will not see the Pi's Bluetooth"
    fi
  fi
done

# Daily certificate expiry check (QA-M-4) and nightly Authentik backup (K5): systemd timers; a failing run shows in `systemctl --failed`,
# the journal and an alert mail. The backup timer is enabled even before the owner has configured the recipient: the first nightly run then
# fails loudly (one mail a day) instead of the gap being silent (docs/runbooks/authentik-backup.md, owner setup).
for u in "${LAB_UNITS[@]}"; do
  render_unit "$REPO_DIR" "$APPS_ROOT" "$u" > "/etc/systemd/system/$u"
  chmod 0644 "/etc/systemd/system/$u"
done
if systemctl daemon-reload 2> /dev/null && systemctl enable --now home-lab-cert-expiry.timer home-lab-alert-test.timer home-lab-backup-authentik.timer home-lab-backup-apps.timer > /dev/null 2>&1 && systemctl enable home-lab-breakglass-reset.service > /dev/null 2>&1; then
  info "home-lab-cert-expiry.timer enabled (daily); home-lab-alert-test.timer enabled (monthly test mail); home-lab-backup-authentik.timer enabled (nightly Authentik backup); home-lab-backup-apps.timer enabled (nightly app backups); home-lab-breakglass-reset.service enabled (boot)"
else
  warn "could not enable the home-lab timers (no systemd?)"
fi

# SEC-M3: root runs the scripts in this checkout, so nobody who can log in may be able to change them.
if [ -n "$(root_tree_offender "$REPO_DIR")" ]; then # any file below it, not just the top directory (NEW-1)
  chown -R root:root "$REPO_DIR"
  info "checkout $REPO_DIR is now owned by root (use sudo git / sudo scripts/deploy.sh)"
fi
chmod -R go-w "$REPO_DIR"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && id -nG "$SUDO_USER" | grep -qw docker; then
  warn "$SUDO_USER is in the docker group (root-equivalent): sudo gpasswd -d $SUDO_USER docker"
fi

step "6/7 AWS CLI v2 (aarch64)"
if command -v aws > /dev/null 2>&1 && aws --version 2>&1 | grep -q '^aws-cli/2\.' && [ "$UPGRADE_AWS" -eq 0 ]; then
  info "already installed: $(aws --version 2>&1 | head -n 1) (use --upgrade-aws to update)"
else
  curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/awscliv2.zip" "$AWSCLI_URL"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/awscliv2.sig" "$AWSCLI_URL.sig"
  export GNUPGHOME="$TMP/gnupg"
  install -d -m 0700 "$GNUPGHOME"
  gpg --batch --quiet --import "$SCRIPT_DIR/pubkeys/awscli-team.asc"
  have_fpr="$(gpg --batch --with-colons --fingerprint | awk -F: '$1=="fpr"{print $10; exit}')"
  want_fpr="${AWSCLI_KEY_FPR// /}"
  [ "$have_fpr" = "$want_fpr" ] || die "vendored AWS CLI key fingerprint mismatch (got $have_fpr)"
  gpg --batch --status-fd 1 --verify "$TMP/awscliv2.sig" "$TMP/awscliv2.zip" 2> /dev/null |
    grep -q "^\[GNUPG:\] VALIDSIG $want_fpr " || die "AWS CLI installer signature verification FAILED; not installing"
  info "signature OK (key fingerprint $AWSCLI_KEY_FPR)"
  unzip -q "$TMP/awscliv2.zip" -d "$TMP"
  "$TMP/aws/install" --update > /dev/null
  info "installed: $(aws --version 2>&1 | head -n 1)"
fi

step "7/7 aws_signing_helper $HELPER_VERSION"
if [ -x "$HELPER_BIN" ] && [ "$(sha256sum "$HELPER_BIN" | cut -d' ' -f1)" = "$HELPER_SHA256" ]; then
  info "already installed with the pinned checksum"
else
  curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/aws_signing_helper" "$HELPER_URL"
  printf '%s  %s\n' "$HELPER_SHA256" "$TMP/aws_signing_helper" | sha256sum -c - > /dev/null ||
    die "aws_signing_helper SHA256 mismatch against the AWS user guide value; not installing"
  install -m 0555 -o root -g root "$TMP/aws_signing_helper" "$HELPER_BIN"
  info "installed $HELPER_BIN (SHA256 verified)"
fi

# Version record for the runbook and later audits (not secret).
{
  printf 'aws-cli=%s\n' "$(aws --version 2>&1 | head -n 1 | cut -d' ' -f1 | cut -d/ -f2)"
  printf 'aws_signing_helper=%s\n' "$HELPER_VERSION"
  printf 'recorded=%s\n' "$(date -u +%FT%TZ)"
} > "$ETC_DIR/installed-versions"
chmod 0600 "$ETC_DIR/installed-versions"

printf '\nBootstrap complete. Next: sudo scripts/preflight.sh --stage bootstrap\n'
