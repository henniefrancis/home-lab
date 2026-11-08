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
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"

STAGE="pre"
while [ $# -gt 0 ]; do
  case "$1" in
    --stage)
      STAGE="${2:-}"
      shift 2 || true
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
    fail docker-engine "docker daemon not reachable (is it running? run this script with sudo or join the docker group)"
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
  https_check letsencrypt-stg "https://acme-staging-v02.api.letsencrypt.org/directory" fail
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
  for d in proxy socket-proxy authentik-internal; do
    if docker network inspect "$d" > /dev/null 2>&1; then pass "net-$d" "docker network exists"; else fail "net-$d" "docker network missing (run bootstrap.sh)"; fi
  done
  # F02: the service uids must not be real host users (a file owned by the login user is readable by whoever logs in).
  local k id
  for k in AUTHENTIK_UID AUTHENTIK_GID AUTHENTIK_PG_UID AUTHENTIK_PG_GID HOMEPAGE_UID HOMEPAGE_GID; do
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
  if lsmod 2> /dev/null | grep -q '^tun'; then pass tun "tun module loaded"; else warnx tun "tun module not loaded (Tailscale needs /dev/net/tun)"; fi
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

check_repo_hygiene() {
  local bad
  [ -d "$REPO_DIR/.git" ] || {
    warnx repo-hygiene "not a git checkout; skipped"
    return
  }
  bad="$(git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" ls-files --others --exclude-standard --ignored 2> /dev/null |
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
  check_repo_hygiene
fi

printf '\nSummary: %d PASS, %d WARN, %d FAIL\n' "$n_pass" "$n_warn" "$n_fail"
if [ "$n_fail" -gt 0 ]; then
  echo "Result: FAIL - fix the items marked [FAIL] and re-run."
  exit 1
fi
[ "$n_warn" -gt 0 ] && echo "Result: PASS with warnings - read each [WARN] and decide." || echo "Result: PASS"
exit 0
