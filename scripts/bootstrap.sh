#!/usr/bin/env bash
# bootstrap.sh - Pi, root, idempotent: prepare the host for the home lab. Contains and writes no secrets.
#
# Usage: sudo scripts/bootstrap.sh [--upgrade-aws]
#
# What it does (safe to re-run; each step skips when already satisfied):
#   1. Refuses to continue if scripts/preflight.sh reports a FAIL.
#   2. apt: curl, unzip, gnupg, jq, openssl, ca-certificates, git (only the missing ones).
#   3. Directory layout: $APPS_ROOT/{traefik,authentik,homepage,tailscale,secrets}, /etc/home-lab, /etc/home-lab/pki; the Authentik
#      data and Postgres directories owned by the service uids from config/lab.env (never the login user).
#   4. Docker networks (plan 6.1): proxy, socket-proxy (internal), authentik-internal (internal).
#   5. Loads and persists the tun kernel module and sets net.ipv4.conf.all.src_valid_mark=1 on the host (Tailscale; the
#      container cannot write /proc/sys, so this is done here instead of adding capabilities).
#   6. Installs AWS CLI v2 (aarch64): official installer, GPG signature verified against the AWS CLI team key.
#   7. Installs aws_signing_helper at the pinned version: SHA256 verified against the AWS user guide value
#      (scripts/lib/pins.sh cites the source), installed 0555 root.
# Plan: docs/plan/phase-1-traefik.md section 6.10. Runbook: docs/runbooks/m2-pi-setup.md.
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/pins.sh
. "$SCRIPT_DIR/lib/pins.sh"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"

UPGRADE_AWS=0
for a in "$@"; do
  case "$a" in
    --upgrade-aws) UPGRADE_AWS=1 ;;
    -h | --help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $a" ;;
  esac
done
require_root "$@"

APPS_ROOT="$(lab_env_get "$LAB_ENV" APPS_ROOT /apps)"
PROXY_SUBNET="$(lab_env_get "$LAB_ENV" PROXY_SUBNET 172.30.0.0/24)"
ETC_DIR=/etc/home-lab

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

step "1/7 Preflight (system checks)"
"$SCRIPT_DIR/preflight.sh" || die "preflight reported FAIL; fix the findings and re-run bootstrap.sh"

step "2/7 Required packages"
missing=()
for pair in curl:curl unzip:unzip gpg:gnupg jq:jq openssl:openssl git:git; do
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
install -d -m 0755 -o root -g root "$APPS_ROOT"
for d in traefik authentik homepage tailscale; do
  install -d -m 0755 -o root -g root "$APPS_ROOT/$d"
done
install -d -m 0700 -o root -g root "$APPS_ROOT/traefik/letsencrypt" "$APPS_ROOT/tailscale/state"
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
for id in "$AK_UID" "$AK_GID" "$PG_UID" "$PG_GID" "$HP_UID" "$HP_GID"; do
  [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -ne 0 ] && [ "$id" -ne 1000 ] || die "service uid/gid '$id' in $LAB_ENV must be numeric, not 0 and not 1000 (the login user)"
done
install -d -m 0700 -o "$AK_UID" -g "$AK_GID" "$APPS_ROOT/authentik/data"
install -d -m 0700 -o "$PG_UID" -g "$PG_GID" "$APPS_ROOT/authentik/postgres"
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
ensure_network socket-proxy --internal
ensure_network authentik-internal --internal

step "5/7 tun kernel module and Tailscale sysctl"
if modprobe tun 2> /dev/null; then
  printf 'tun
' > /etc/modules-load.d/home-lab.conf
  info "tun loaded and persisted in /etc/modules-load.d/home-lab.conf"
else
  warn "could not load the tun module; Tailscale needs /dev/net/tun"
fi
# Tailscale marks its packets and wants src_valid_mark=1 (reverse-path filtering with fwmark routing). The container
# runs with host networking but a read-only /proc/sys, so it logs "failed to enable src_valid_mark"; the host sets it.
SYSCTL_FILE=/etc/sysctl.d/99-home-lab.conf
SYSCTL_WANT=$'# Managed by home-lab scripts/bootstrap.sh
net.ipv4.conf.all.src_valid_mark = 1
'
if [ "$(cat "$SYSCTL_FILE" 2> /dev/null || true)" != "${SYSCTL_WANT%$'
'}" ]; then
  printf '%s' "$SYSCTL_WANT" > "$SYSCTL_FILE"
  chmod 0644 "$SYSCTL_FILE"
  info "wrote $SYSCTL_FILE"
fi
if sysctl -q -p "$SYSCTL_FILE" > /dev/null 2>&1; then
  info "net.ipv4.conf.all.src_valid_mark=$(sysctl -n net.ipv4.conf.all.src_valid_mark) (persisted)"
else
  warn "could not apply $SYSCTL_FILE; Tailscale may log 'failed to enable src_valid_mark' (harmless once the value is 1)"
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
