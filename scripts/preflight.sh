#!/usr/bin/env bash
# preflight.sh - Pi: read-only readiness report with a PASS/WARN/FAIL summary. Changes nothing.
#
# Usage:
#   scripts/preflight.sh                   system checks only (before bootstrap; no root needed)
#   sudo scripts/preflight.sh --stage bootstrap   + installed tools, directories, Docker networks (after bootstrap.sh)
#   sudo scripts/preflight.sh --stage full        + aws.env, PKI files, secrets dir, repo hygiene (end of M2)
#
# Exit code: 0 = no FAIL (WARNs allowed), 1 = at least one FAIL, 2 = usage error.
# Plan: docs/plan/phase-1-traefik.md sections 6.10 and 2 (A1-A4). Runbook: docs/runbooks/m2-pi-setup.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/pins.sh
. "$SCRIPT_DIR/lib/pins.sh"
# shellcheck source=lib/verify-commit.sh
. "$SCRIPT_DIR/lib/verify-commit.sh"
# shellcheck source=lib/units.sh
. "$SCRIPT_DIR/lib/units.sh"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"

STAGE="pre"
while [ $# -gt 0 ]; do
  case "$1" in
    --stage)
      [ $# -ge 2 ] || {
        echo "--stage needs a value (pre, bootstrap or full)" >&2
        exit 2
      }
      STAGE="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
case "$STAGE" in pre | bootstrap | full) ;; *)
  echo "--stage must be pre, bootstrap or full" >&2
  exit 2
  ;;
esac
if [ "$STAGE" != pre ] && [ "$(id -u)" -ne 0 ]; then
  echo "--stage $STAGE reads root-only paths: run with sudo." >&2
  exit 2
fi

APPS_ROOT="$(lab_env_get "$LAB_ENV" APPS_ROOT /apps)"
LAN_CIDR="$(lab_env_get "$LAB_ENV" LAN_CIDR 10.0.0.0/24)"
ETC_DIR="/etc/home-lab"
PKI_DIR="$ETC_DIR/pki"

n_pass=0
n_warn=0
n_fail=0
pass() {
  n_pass=$((n_pass + 1))
  printf '[PASS] %-22s %s\n' "$1" "${2:-}"
}
warnx() {
  n_warn=$((n_warn + 1))
  printf '[WARN] %-22s %s\n' "$1" "${2:-}"
}
fail() {
  n_fail=$((n_fail + 1))
  printf '[FAIL] %-22s %s\n' "$1" "${2:-}"
}
hint() { printf '         -> %s\n' "$*"; }

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(((a << 24) + (b << 16) + (c << 8) + d))
}
in_cidr() { # in_cidr <ip> <net/bits>
  local net bits mask
  net="${2%/*}"
  bits="${2#*/}"
  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  [ $(($(ip2int "$1") & mask)) -eq $(($(ip2int "$net") & mask)) ]
}
mode_of() { stat -L -c '%a' "$1" 2> /dev/null; }
owner_of() { stat -L -c '%u:%g' "$1" 2> /dev/null; }

# ---------------------------------------------------------------- system checks
check_arch() {
  local m dpkgarch bits model
  m="$(uname -m)"
  bits="$(getconf LONG_BIT 2> /dev/null || echo '?')"
  dpkgarch="$(dpkg --print-architecture 2> /dev/null || echo unknown)"
  model="$({ tr -d '\0' < /proc/device-tree/model; } 2> /dev/null || echo 'unknown board')"
  if [ "$m" = aarch64 ] && [ "$dpkgarch" = arm64 ] && [ "$bits" = 64 ]; then
    pass arch "kernel=$m userland=$dpkgarch ($model)"
  else
    fail arch "kernel=$m userland=$dpkgarch bits=$bits ($model)"
    hint "A Raspberry Pi 4 needs Raspberry Pi OS (64-bit): the pinned binaries are arm64. A 32-bit userland must be reflashed."
  fi
}

check_os() {
  local id ver pretty
  # shellcheck disable=SC1091
  id="$(. /etc/os-release 2> /dev/null && echo "${ID:-unknown}")"
  ver="$(. /etc/os-release 2> /dev/null && echo "${VERSION_ID:-0}")"
  pretty="$(. /etc/os-release 2> /dev/null && echo "${PRETTY_NAME:-unknown}")"
  case "$id" in
    debian | raspbian)
      if [ "${ver%%.*}" -ge 12 ] 2> /dev/null; then
        pass os "$pretty"
      else
        fail os "$pretty (Debian 12 or newer required)"
      fi
      ;;
    *) warnx os "$pretty (not Debian or Raspberry Pi OS; the scripts are untested here)" ;;
  esac
}

check_boot_device() {
  local src disk tran rot
  src="$(findmnt -n -o SOURCE / 2> /dev/null || true)"
  disk="$(lsblk -no PKNAME "$src" 2> /dev/null | head -n 1 || true)"
  if [ -z "$disk" ]; then
    warnx boot-device "could not determine the root disk (source='${src:-?}')"
    return
  fi
  tran="$(lsblk -dno TRAN "/dev/$disk" 2> /dev/null | head -n 1 || true)"
  rot="$(cat "/sys/block/$disk/queue/rotational" 2> /dev/null || echo 0)"
  case "$disk" in
    mmcblk*)
      warnx boot-device "root on SD card (/dev/$disk)"
      hint "SD cards wear out under Docker, Postgres and logs. Move to a USB 3 SSD (plan R5)."
      ;;
    nvme*) pass boot-device "root on NVMe (/dev/$disk)" ;;
    *)
      if [ "$rot" = 1 ]; then
        warnx boot-device "root on a spinning disk (/dev/$disk, transport=${tran:-?}); an SSD is recommended"
      else
        pass boot-device "root on /dev/$disk (transport=${tran:-?}, non-rotational)"
      fi
      ;;
  esac
}

check_memory_cgroup() {
  local ok=no ctl=/sys/fs/cgroup/cgroup.controllers
  if [ -r "$ctl" ]; then
    grep -qw memory "$ctl" && ok=yes
  elif [ "$(awk '$1=="memory"{print $4}' /proc/cgroups 2> /dev/null)" = 1 ]; then
    ok=yes
  fi
  if [ "$ok" = yes ]; then
    pass memory-cgroup "memory controller enabled (container memory limits work)"
  else
    fail memory-cgroup "memory cgroup is disabled; Docker memory limits would be ignored"
    hint "Append 'cgroup_memory=1 cgroup_enable=memory' to the ONE line in /boot/firmware/cmdline.txt"
    hint "(/boot/cmdline.txt on older images), unless already present, then reboot:"
    hint "  sudo sed -i '1 s/\$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt && sudo reboot"
  fi
}

check_docker() {
  local dv cv
  if ! command -v docker > /dev/null 2>&1; then
    fail docker "docker is not installed"
    hint "Install Docker Engine from Docker's official apt repository for Debian:"
    hint "  https://docs.docker.com/engine/install/debian/  (also add the compose plugin: docker-compose-plugin)"
    return
  fi
  if dpkg -s docker-ce > /dev/null 2>&1; then
    pass docker-pkg "docker-ce from Docker's apt repository"
  else
    warnx docker-pkg "docker-ce package not found (Debian's docker.io or another source?); plan A1 expects Docker's apt repo"
  fi
  if dv="$(docker version --format '{{.Server.Version}}' 2> /dev/null)" && [ -n "$dv" ]; then
    pass docker-engine "Engine $dv"
  else
    fail docker-engine "docker daemon not reachable (is it running? the login user is deliberately NOT in the docker group: run this script with sudo)"
  fi
  cv="$(docker compose version --short 2> /dev/null || true)"
  cv="${cv#v}"
  if [ -z "$cv" ]; then
    fail compose "Compose v2 plugin not found"
    hint "sudo apt-get install docker-compose-plugin  (from Docker's apt repo)"
  elif ver_ge "$cv" 2.20; then
    pass compose "Compose $cv (>= 2.20)"
  else
    fail compose "Compose $cv is older than 2.20 (needed for include:)"
  fi
}

check_network() {
  local dev ip dyn mac
  dev="$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)"
  ip="$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' | head -n 1)"
  if [ -z "$dev" ] || [ -z "$ip" ]; then
    fail lan-ip "no default IPv4 route"
    return
  fi
  mac="$(cat "/sys/class/net/$dev/address" 2> /dev/null || echo '?')"
  if in_cidr "$ip" "$LAN_CIDR"; then
    pass lan-ip "$ip on $dev, inside LAN_CIDR $LAN_CIDR"
  else
    fail lan-ip "$ip on $dev is outside LAN_CIDR $LAN_CIDR (config/lab.env and the Traefik allow-list would block you)"
  fi
  case "$dev" in
    wl*) warnx link "Wi-Fi ($dev); wired Ethernet is recommended for a server" ;;
    *) pass link "$dev" ;;
  esac
  dyn="$(ip -4 -o addr show dev "$dev" 2> /dev/null | grep -c dynamic || true)"
  if [ "${dyn:-0}" -gt 0 ]; then
    warnx ip-reservation "$ip is DHCP-assigned; a reservation cannot be detected from the Pi"
    hint "Create a DHCP reservation for $dev MAC $mac -> $ip in the router (U5), then ignore this WARN."
  else
    pass ip-reservation "$ip looks statically configured"
  fi
}

check_ssh() {
  local unit="" active enabled pw=unknown
  for u in ssh sshd; do
    if systemctl cat "$u.service" > /dev/null 2>&1; then
      unit="$u"
      break
    fi
  done
  if [ -z "$unit" ]; then
    pass ssh "no SSH server installed (Raspberry Pi Connect is the access path; break-glass)"
    return
  fi
  active="$(systemctl is-active "$unit" 2> /dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2> /dev/null || true)"
  if [ "$(id -u)" -eq 0 ] && command -v sshd > /dev/null 2>&1; then
    pw="$(sshd -T 2> /dev/null | awk '$1=="passwordauthentication"{print $2}')"
    pw="${pw:-unknown}"
  fi
  if [ "$pw" = yes ]; then
    warnx ssh "$unit active=$active enabled=$enabled; password authentication is ON (key-only is recommended, A4)"
  else
    pass ssh "$unit active=$active enabled=$enabled password-auth=$pw"
  fi
}

check_disk() {
  local kb gb
  kb="$(df -Pk / | awk 'NR==2{print $4}')"
  gb="$((kb / 1024 / 1024))"
  if [ "$kb" -lt $((2 * 1024 * 1024)) ]; then
    fail disk "only ${gb} GiB free on / (need 2 GiB minimum)"
  elif [ "$kb" -lt $((8 * 1024 * 1024)) ]; then
    warnx disk "${gb} GiB free on / (8 GiB or more is comfortable for images and Postgres)"
  else
    pass disk "${gb} GiB free on /"
  fi
}

check_time() {
  local sync
  sync="$(timedatectl show -p NTPSynchronized --value 2> /dev/null || true)"
  case "$sync" in
    yes) pass time-sync "clock is NTP-synchronised ($(date -u +%FT%TZ))" ;;
    no)
      fail time-sync "clock is not synchronised; Roles Anywhere signing and TLS fail with clock skew"
      hint "sudo timedatectl set-ntp true   (and check the network allows NTP)"
      ;;
    *) warnx time-sync "could not determine NTP status (timedatectl unavailable)" ;;
  esac
}

https_check() { # https_check <label> <url> <fail|warn>
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$2" 2> /dev/null || true)"
  if [ -n "$code" ] && [ "$code" != 000 ]; then
    pass "https:$1" "reachable (HTTP $code)"
  elif [ "$3" = fail ]; then
    fail "https:$1" "no HTTPS response from $2"
  else
    warnx "https:$1" "no HTTPS response from $2"
  fi
}

# K7: the ACME directory the lab is configured for (config/lab.env ACME_CA_SERVER) must be reachable. Production is the goal; staging
# (the M3 default) only warns, because its certificates are not trusted by browsers.
check_acme_endpoint() {
  local url env want
  url="$(lab_env_get "$LAB_ENV" ACME_CA_SERVER)"
  env="$(lab_env_get "$LAB_ENV" ACME_ENV)"
  # QA-M-1: the certificate store file is named after ACME_ENV and the CA after ACME_CA_SERVER; they must agree, or Traefik keeps
  # serving the old environment's certificate behind the new CA URL (a half-applied M6 step 1).
  case "$url" in
    https://acme-v02.api.letsencrypt.org/directory) want=prod ;;
    https://acme-staging-v02.api.letsencrypt.org/directory) want=staging ;;
    *) want="" ;;
  esac
  if [ -n "$want" ] && [ "$env" != "$want" ]; then
    fail acme-env-match "ACME_ENV='$env' does not match ACME_CA_SERVER ($want): set both in config/lab.env (the store file acme-<ACME_ENV>.json is chosen by ACME_ENV)"
  elif [ -n "$want" ]; then
    pass acme-env-match "ACME_ENV=$env matches ACME_CA_SERVER"
  fi
  case "$url" in
    https://acme-v02.api.letsencrypt.org/directory)
      https_check letsencrypt-prod "$url" fail
      ;;
    https://acme-staging-v02.api.letsencrypt.org/directory)
      https_check letsencrypt-stg "$url" fail
      warnx acme-env "ACME_CA_SERVER is the Let's Encrypt STAGING directory: browsers do not trust the certificate (switch at M6, docs/runbooks/m6-go-live.md)"
      ;;
    '')
      fail acme-env "ACME_CA_SERVER is not set in config/lab.env"
      ;;
    *)
      fail acme-env "ACME_CA_SERVER is neither the Let's Encrypt production nor the staging directory: '$url' (check for quotes or a trailing space in config/lab.env)"
      ;;
  esac
}

check_outbound() {
  local region
  region="$(lab_env_get "$LAB_ENV" AWS_SSM_REGION af-south-1)"
  if ! command -v curl > /dev/null 2>&1; then
    fail outbound-https "curl is not installed (sudo apt-get install curl)"
    return
  fi
  https_check ssm "https://ssm.$region.amazonaws.com/" fail
  https_check rolesanywhere "https://rolesanywhere.$region.amazonaws.com/" fail
  https_check awscli-download "https://awscli.amazonaws.com/" fail
  https_check helper-download "https://rolesanywhere.amazonaws.com/" fail
  https_check tailscale "https://controlplane.tailscale.com/" fail
  check_acme_endpoint
  https_check dockerhub "https://registry-1.docker.io/v2/" warn
  https_check ghcr "https://ghcr.io/v2/" warn
  https_check github "https://github.com/" warn
}

check_lan_allowlist() {
  local f="$REPO_DIR/traefik/dynamic/middlewares.yml"
  [ -f "$f" ] || return 0
  if grep -qF "$LAN_CIDR" "$f" && grep -qF "$(lab_env_get "$LAB_ENV" TAILNET_CIDR 100.64.0.0/10)" "$f"; then
    pass lan-allowlist "middlewares.yml matches LAN_CIDR and TAILNET_CIDR in config/lab.env"
  else
    fail lan-allowlist "traefik/dynamic/middlewares.yml sourceRange does not match config/lab.env"
  fi
}

# ---------------------------------------------------------------- bootstrap-stage checks
check_installed_tools() {
  local v
  if command -v aws > /dev/null 2>&1; then
    v="$(aws --version 2>&1 | head -n 1)"
    case "$v" in aws-cli/2.*) pass aws-cli "$v" ;; *) fail aws-cli "expected AWS CLI v2, found: $v" ;; esac
  else
    fail aws-cli "aws CLI v2 not installed (run bootstrap.sh)"
  fi
  if [ -x "$HELPER_BIN" ]; then
    if [ "$(sha256sum "$HELPER_BIN" | cut -d' ' -f1)" = "$HELPER_SHA256" ] && [ "$(mode_of "$HELPER_BIN")" = 555 ]; then
      pass aws_signing_helper "pinned version $HELPER_VERSION, checksum matches, mode 0555"
    else
      fail aws_signing_helper "$HELPER_BIN does not match pinned $HELPER_VERSION checksum or mode 0555 (re-run bootstrap.sh)"
    fi
  else
    fail aws_signing_helper "$HELPER_BIN not installed (run bootstrap.sh)"
  fi
  if command -v jq > /dev/null 2>&1; then pass jq "$(jq --version)"; else fail jq "jq missing (run bootstrap.sh)"; fi
  # K5: the Authentik backup is encrypted on the Pi with age before it leaves (scripts/backup-authentik.sh).
  if command -v age > /dev/null 2>&1; then pass age "$(age --version 2> /dev/null | head -n 1)"; else fail age "age missing (run bootstrap.sh): the nightly Authentik backup cannot run"; fi
}

check_dir() { # check_dir <path> <owner uid:gid> <mode> <label>
  if [ ! -e "$1" ]; then
    fail "$4" "$1 missing (run bootstrap.sh)"
  elif [ "$(owner_of "$1")" = "$2" ] && [ "$(mode_of "$1")" = "$3" ]; then
    pass "$4" "$1 owner=$2 mode=0$3"
  else
    fail "$4" "$1 is owner=$(owner_of "$1") mode=0$(mode_of "$1"); expected owner=$2 mode=0$3"
  fi
}

check_layout() {
  local d
  check_dir "$ETC_DIR" 0:0 700 etc-home-lab
  check_dir "$PKI_DIR" 0:0 700 pki-dir
  check_dir "$APPS_ROOT/secrets" 0:0 700 secrets-dir
  for d in traefik authentik homepage tailscale; do
    if [ -d "$APPS_ROOT/$d" ]; then pass "apps-$d" "$APPS_ROOT/$d"; else fail "apps-$d" "$APPS_ROOT/$d missing (run bootstrap.sh)"; fi
  done
  for d in proxy authentik-internal authentik-auth; do
    if docker network inspect "$d" > /dev/null 2>&1; then pass "net-$d" "docker network exists"; else fail "net-$d" "docker network missing (run bootstrap.sh)"; fi
  done
  # F02: the service uids must not be real host users (a file owned by the login user is readable by whoever logs in).
  local k id
  for k in AUTHENTIK_UID AUTHENTIK_GID AUTHENTIK_PG_UID AUTHENTIK_PG_GID HOMEPAGE_UID HOMEPAGE_GID TRAEFIK_UID TRAEFIK_GID; do
    id="$(lab_env_get "$LAB_ENV" "$k")"
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
      fail "svc-id:$k" "$k missing or not numeric in $LAB_ENV"
    elif [ "$id" -eq 0 ] || [ "$id" -eq 1000 ]; then
      fail "svc-id:$k" "$k=$id must not be 0 or the login uid 1000"
    elif getent passwd "$id" > /dev/null 2>&1 || getent group "$id" > /dev/null 2>&1; then
      fail "svc-id:$k" "$k=$id is a real host user or group; choose an unused id"
    else
      pass "svc-id:$k" "$k=$id is not a host user or group"
    fi
  done
  if [ -d "$APPS_ROOT/authentik/data" ]; then
    check_dir "$APPS_ROOT/authentik/data" "$(lab_env_get "$LAB_ENV" AUTHENTIK_UID):$(lab_env_get "$LAB_ENV" AUTHENTIK_GID)" 700 authentik-data
    check_dir "$APPS_ROOT/authentik/postgres" "$(lab_env_get "$LAB_ENV" AUTHENTIK_PG_UID):$(lab_env_get "$LAB_ENV" AUTHENTIK_PG_GID)" 700 authentik-postgres
  else
    fail authentik-data "$APPS_ROOT/authentik/data missing (re-run bootstrap.sh)"
  fi
  # Under pipefail, `lsmod | grep -q` reported a loaded module as missing: grep -q exits at the first match, lsmod dies of SIGPIPE on its next
  # write and the pipeline fails (seen live 2026-11-10). What Tailscale needs is the device, whether tun is a module or built in.
  if [ -c /dev/net/tun ]; then pass tun "/dev/net/tun present (kernel TUN for Tailscale)"; else warnx tun "/dev/net/tun missing (Tailscale needs it: sudo modprobe tun)"; fi
}

# ---------------------------------------------------------------- full-stage checks
cert_field() { openssl x509 -in "$1" -noout -subject -nameopt RFC2253 2> /dev/null | sed 's/^subject=//'; }

check_aws_env() {
  local f="$ETC_DIR/aws.env" k
  if [ ! -f "$f" ]; then
    fail aws-env "$f missing (U13: write it from terraform output, runbook step 9)"
    return
  fi
  if [ "$(mode_of "$f")" = 600 ] && [ "$(owner_of "$f")" = 0:0 ]; then
    pass aws-env-perms "$f root 0600"
  else
    fail aws-env-perms "$f must be root:root 0600 (is $(owner_of "$f") 0$(mode_of "$f"))"
  fi
  for k in AWS_REGION RA_TRUST_ANCHOR_ARN RA_HOST_PROFILE_ARN RA_HOST_ROLE_ARN; do
    if [ -n "$(lab_env_get "$f" "$k")" ]; then pass "aws-env:$k" "set"; else fail "aws-env:$k" "missing in $f"; fi
  done
}

check_pki() {
  local gen name subj owner want_cn
  gen="$(lab_env_get "$ETC_DIR/aws.env" PKI_GENERATION gen-1)"
  for name in host traefik; do
    case "$name" in host) owner=0:0 want_cn=home-lab-pi-host ;; *) owner=10001:10001 want_cn=home-lab-pi-traefik ;; esac
    if [ ! -f "$PKI_DIR/$name.key" ]; then
      fail "pki-$name-key" "$PKI_DIR/$name.key missing (run pki-pi-csr.sh)"
    elif [ "$(mode_of "$PKI_DIR/$name.key")" = 400 ] && [ "$(owner_of "$PKI_DIR/$name.key")" = "$owner" ]; then
      pass "pki-$name-key" "owner=$owner mode=0400"
    else
      fail "pki-$name-key" "must be owner=$owner mode=0400 (is $(owner_of "$PKI_DIR/$name.key") 0$(mode_of "$PKI_DIR/$name.key"))"
    fi
    if [ ! -f "$PKI_DIR/$name.crt" ]; then
      fail "pki-$name-cert" "$PKI_DIR/$name.crt missing (sign the CSR on the laptop, then pi-install-cert.sh)"
      continue
    fi
    subj="$(cert_field "$PKI_DIR/$name.crt")"
    if [ "$(printf '%s' "$subj" | tr ',' '\n' | sort | paste -sd,)" = "$(printf 'CN=%s\nOU=%s\n' "$want_cn" "$gen" | sort | paste -sd,)" ]; then
      pass "pki-$name-subject" "CN=$want_cn OU=$gen"
    else
      fail "pki-$name-subject" "subject '$subj' does not match CN=$want_cn OU=$gen"
    fi
    if [ "$(openssl x509 -in "$PKI_DIR/$name.crt" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')" = "CN=home-lab-offline-ca" ]; then
      pass "pki-$name-issuer" "CN=home-lab-offline-ca"
    else
      fail "pki-$name-issuer" "issuer is not CN=home-lab-offline-ca"
    fi
  done
  if [ -x "$SCRIPT_DIR/cert-expiry.sh" ]; then
    while IFS= read -r line; do
      case "$line" in
        '[PASS]'*) pass "cert-expiry" "${line#\[PASS\] }" ;;
        '[WARN]'*) warnx "cert-expiry" "${line#\[WARN\] }" ;;
        '[FAIL]'*) fail "cert-expiry" "${line#\[FAIL\] }" ;;
      esac
    done < <("$SCRIPT_DIR/cert-expiry.sh" 2> /dev/null || true)
  fi
}

# SEC-M3, SEC-M7, SEC-L2, SEC-L3, QA-M-4: who can reach root, signed deploys, listeners, break-glass, expiry timer.
check_hardening() {
  local login="${SUDO_USER:-}" owner groups listeners
  # Security checks never pipe into `grep -q` (pipefail plus SIGPIPE can turn a match into "no match", so a finding would PASS): the
  # output is captured first and grep reads it from a here-string.
  if [ -n "$login" ] && [ "$login" != root ]; then
    groups="$(id -nG "$login" 2> /dev/null)"
    if grep -qw docker <<< "$groups"; then
      fail login-docker-group "$login is in the docker group, which is root-equivalent: sudo gpasswd -d $login docker, then log in again (use sudo docker)"
    else
      pass login-docker-group "$login is not in the docker group"
    fi
  else
    warnx login-docker-group "no SUDO_USER: cannot tell which login user to check"
  fi
  # NEW-1: the whole tree (.git, scripts, hooks), not just the top directory; the same test deploy.sh enforces.
  owner="$(root_tree_offender "$REPO_DIR" 2> /dev/null || echo "(find failed)")"
  if [ -z "$owner" ]; then
    pass checkout-owner "$REPO_DIR (whole tree, .git included) is root-owned and not writable by others"
  else
    fail checkout-owner "$owner is not root-owned or is group/world writable (root runs this checkout's scripts): sudo chown -R root:root $REPO_DIR && sudo chmod -R go-w $REPO_DIR"
  fi
  if allowed_signers_usable "${HOME_LAB_ALLOWED_SIGNERS:-$ETC_DIR/allowed_signers}"; then
    pass allowed-signers "${HOME_LAB_ALLOWED_SIGNERS:-$ETC_DIR/allowed_signers} has a usable signing key (deploy.sh verifies commits)"
  else
    fail allowed-signers "${HOME_LAB_ALLOWED_SIGNERS:-$ETC_DIR/allowed_signers} missing, writable by others or placeholder-only: deploy.sh would refuse (runbook: signed deploys)"
  fi
  if command -v ssh-keygen > /dev/null 2>&1; then pass ssh-keygen "available (signature verification)"; else fail ssh-keygen "missing: apt-get install openssh-client"; fi
  if [ -e "${BREAKGLASS_DIR:-$APPS_ROOT/traefik/dynamic}/bg-traefik.yml" ]; then
    warnx break-glass "ENABLED: the Traefik dashboard accepts the Basic-auth login. Disable it: sudo scripts/breakglass.sh off"
  else
    pass break-glass "not enabled"
  fi
  if command -v ss > /dev/null 2>&1; then
    listeners="$(ss -H -tln 2> /dev/null | awk '{print $4}')"
    if grep -qxF -e '[::]:80' -e '[::]:443' <<< "$listeners"; then
      fail ports-ipv6 "a listener on [::]:80 or [::]:443 exists: a global IPv6 address would expose Traefik (publish IPv4 only, see traefik/compose.yaml)"
    else
      pass ports-ipv6 "no wildcard IPv6 listener on 80/443"
    fi
  fi
  check_units
}

# QA-M-3: units are installed by bootstrap.sh, not by deploy.sh. A unit changed by a release but never installed leaves the alert path
# half-wired, so compare every installed unit with the repository copy and check the timers are enabled.
check_units() {
  local drift t
  drift="$(unit_drift "$REPO_DIR" "$APPS_ROOT")"
  if [ -z "$drift" ]; then
    pass systemd-units "installed units match the repository copy"
  else
    fail systemd-units "stale or missing systemd units (run: sudo scripts/bootstrap.sh): $(printf '%s' "$drift" | paste -sd";" -)"
  fi
  for t in home-lab-cert-expiry.timer home-lab-alert-test.timer home-lab-backup-authentik.timer; do
    if systemctl is-enabled "$t" > /dev/null 2>&1; then
      pass "timer-${t%.timer}" "$t is enabled"
    else
      warnx "timer-${t%.timer}" "$t is not enabled (re-run bootstrap.sh)"
    fi
  done
}

# K4: the certificate Traefik really serves, and the alert path.
check_alerting() {
  local line rc=0 topic tf
  if [ -x "$SCRIPT_DIR/served-cert-check.sh" ]; then
    line="$("$SCRIPT_DIR/served-cert-check.sh" 2> /dev/null)" || rc=$?
    case "$line" in
      '[PASS]'*) pass served-cert "${line#\[PASS\] served-cert: }" ;;
      '[WARN]'*) warnx served-cert "${line#\[WARN\] served-cert: }" ;;
      '[FAIL]'*)
        # rc 3 = nothing answered on 127.0.0.1:443: Traefik is not up yet (early milestones), not a certificate problem.
        # rc 4 = the check could not run: a FAIL (the alert path is blind), not a Traefik-down warning.
        if [ "$rc" -eq 3 ]; then warnx served-cert "${line#\[FAIL\] served-cert: }"; else fail served-cert "${line#\[FAIL\] served-cert: }"; fi
        ;;
      *) warnx served-cert "served-cert-check.sh gave no result" ;;
    esac
  else
    warnx served-cert "scripts/served-cert-check.sh missing or not executable"
  fi
  topic="$(lab_env_get "$ETC_DIR/aws.env" ALERT_TOPIC_ARN)"
  if [[ "$topic" =~ ^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$ ]]; then
    pass alert-topic "ALERT_TOPIC_ARN is set in $ETC_DIR/aws.env (send a test mail: sudo scripts/alert.sh test)"
  else
    warnx alert-topic "ALERT_TOPIC_ARN is missing or malformed in $ETC_DIR/aws.env (no quotes or spaces): no alert reaches a person (docs/runbooks/alerting.md)"
  fi
  # SEC-M-2: the monthly heartbeat must have published a test mail recently (the proof that it ARRIVED is the mail itself).
  tf="${HOME_LAB_STATE_DIR:-/var/lib/home-lab}/alert-test.published"
  if [ -r "$tf" ] && [ $(($(date +%s) - $(stat -c %Y "$tf" 2> /dev/null || echo 0))) -lt $((35 * 86400)) ]; then
    pass alert-heartbeat "a test alert was published within the last 35 days (did the mail arrive? the monthly mail is the proof)"
  else
    warnx alert-heartbeat "no test alert published in the last 35 days: run sudo scripts/alert.sh test and confirm the mail arrives (docs/runbooks/alerting.md)"
  fi
}

# K5: the Authentik backup. Configured (public recipient and bucket in aws.env), and a SUCCESSFUL run recently: the last-success file is
# written by scripts/backup-authentik.sh only after the dump, the encryption, the upload and the completion marker all worked.
# WARN after 2 days (one missed night is noise, two is a problem), FAIL after 7 days; "never" is a WARN (not run yet, or not set up).
check_backup() {
  local f="$ETC_DIR/aws.env" rec bucket sf last now age configured=1
  rec="$(lab_env_get "$f" BACKUP_AGE_RECIPIENT)"
  bucket="$(lab_env_get "$f" BACKUP_S3_BUCKET)"
  if [[ "$rec" =~ ^age1[02-9ac-hj-np-z]{58}$ ]]; then
    pass backup-recipient "BACKUP_AGE_RECIPIENT is set (a public key; the private identity must exist only in the password manager)"
  else
    configured=0
    warnx backup-recipient "BACKUP_AGE_RECIPIENT is missing or not an age public key (age1...) in $f: no Authentik backup can be taken"
    hint "docs/runbooks/authentik-backup.md, owner setup: age-keygen on the laptop, then scripts/render-aws-env.sh --age-recipient age1..."
  fi
  if [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    pass backup-bucket "BACKUP_S3_BUCKET is set"
  else
    configured=0
    warnx backup-bucket "BACKUP_S3_BUCKET is missing or malformed in $f (terraform output backup_bucket_name, scripts/render-aws-env.sh)"
  fi
  if [ -e "$ETC_DIR/restore-pending" ]; then
    warnx backup-restore-pending "$ETC_DIR/restore-pending exists: nightly backups are SKIPPED until you remove it. Remove it right after the Authentik restore (docs/runbooks/authentik-backup.md section 4)"
  fi
  sf="${HOME_LAB_STATE_DIR:-/var/lib/home-lab}/backup-authentik.last"
  now="$(date +%s)"
  last="$(head -c 20 "$sf" 2> /dev/null | tr -d '\n' || true)"
  if ! [[ "$last" =~ ^[0-9]{1,11}$ ]]; then
    if [ "$configured" -eq 1 ]; then
      warnx backup-last "no successful Authentik backup recorded yet (never): sudo systemctl start home-lab-backup-authentik.service, then check the object exists"
    else
      warnx backup-last "no successful Authentik backup recorded (never); set it up first (docs/runbooks/authentik-backup.md)"
    fi
    return
  fi
  last=$((10#$last))
  age=$((now - last))
  if [ "$age" -lt 0 ]; then
    warnx backup-last "the last-success time is in the future (the Pi has no RTC and the clock is wrong?): check timedatectl"
  elif [ "$age" -gt $((7 * 86400)) ]; then
    fail backup-last "the last successful Authentik backup is $((age / 86400)) days old (limit 7): journalctl -u home-lab-backup-authentik.service, docs/runbooks/authentik-backup.md"
  elif [ "$age" -gt $((2 * 86400)) ]; then
    warnx backup-last "the last successful Authentik backup is $((age / 86400)) days old (a night was missed): journalctl -u home-lab-backup-authentik.service"
  else
    pass backup-last "the last successful Authentik backup was $((age / 3600)) hours ago"
  fi
}

check_repo_hygiene() {
  local bad
  [ -d "$REPO_DIR/.git" ] || {
    warnx repo-hygiene "not a git checkout; skipped"
    return
  }
  bad="$(git -c core.hooksPath=/dev/null -C "$REPO_DIR" ls-files --others --exclude-standard --ignored 2> /dev/null |
    grep -E '(^|/)(\.env(\..*)?|secrets/.*|.*\.(pem|key|csr)|acme.*\.json|.*\.tfvars)$' || true)"
  if [ -z "$bad" ]; then
    pass repo-hygiene "no secret-looking files in the repo checkout"
  else
    fail repo-hygiene "secret-looking files in the repo checkout (names below); move them out of the repo"
    printf '%s\n' "$bad" | sed 's/^/         /'
  fi
}

# ---------------------------------------------------------------- run
printf 'home-lab preflight (stage: %s) on %s\n\n' "$STAGE" "$(hostname)"
check_arch
check_os
check_boot_device
check_memory_cgroup
check_docker
check_network
check_ssh
check_disk
check_time
check_outbound
check_lan_allowlist
if [ "$STAGE" != pre ]; then
  check_installed_tools
  check_layout
fi
if [ "$STAGE" = full ]; then
  check_aws_env
  check_pki
  check_hardening
  check_alerting
  check_backup
  check_repo_hygiene
fi

printf '\nSummary: %d PASS, %d WARN, %d FAIL\n' "$n_pass" "$n_warn" "$n_fail"
if [ "$n_fail" -gt 0 ]; then
  echo "Result: FAIL - fix the items marked [FAIL] and re-run."
  exit 1
fi
[ "$n_warn" -gt 0 ] && echo "Result: PASS with warnings - read each [WARN] and decide." || echo "Result: PASS"
exit 0
