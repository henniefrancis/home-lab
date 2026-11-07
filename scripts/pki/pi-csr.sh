#!/usr/bin/env bash
# pi-csr.sh - PI, root: generate the two Roles Anywhere private keys ON THE PI and print their CSRs.
#
# Usage: sudo scripts/pki/pi-csr.sh [--generation gen-1] [--rotate-keys] [--pki-dir DIR] [--no-chown]
#
# Creates under /etc/home-lab/pki (0700 root):
#   traefik.key   ECDSA P-256, owner 10001:10001 mode 0400  (mounted only into the ra-helper container, milestone M3)
#   host.key      ECDSA P-256, owner root:root   mode 0400  (never mounted into any container)
#   traefik.csr / host.csr   (public; printed so you can copy them to the laptop)
# Subjects: CN=home-lab-pi-traefik / CN=home-lab-pi-host, each with OU=<generation> (must equal Terraform pki_generation).
# An existing key is REUSED (renewal) unless --rotate-keys is given. Private keys are never printed or logged.
# --pki-dir and --no-chown exist for the automated self-test (scripts/pki/test-pki.sh).
set -euo pipefail
umask 077

GEN="gen-1"
PKI_DIR="/etc/home-lab/pki"
ROTATE=0
CHOWN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --generation)
      GEN="${2:?}"
      shift 2
      ;;
    --pki-dir)
      PKI_DIR="${2:?}"
      shift 2
      ;;
    --rotate-keys)
      ROTATE=1
      shift
      ;;
    --no-chown)
      CHOWN=0
      shift
      ;;
    -h | --help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$GEN" =~ ^[A-Za-z0-9-]{1,32}$ ]] || die "--generation must be 1-32 letters, digits or hyphens"
if [ "$CHOWN" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then die "run as root: sudo $0 ..."; fi
command -v openssl > /dev/null || die "openssl not found"
[ -d "$PKI_DIR" ] || die "$PKI_DIR missing (run bootstrap.sh first)"

make_identity() { # make_identity <name> <CN> <uid:gid>
  local name="$1" cn="$2" owner="$3" key csr cnf tmpkey
  key="$PKI_DIR/$name.key"
  csr="$PKI_DIR/$name.csr"
  if [ -f "$key" ] && [ "$ROTATE" -eq 0 ]; then
    openssl pkey -in "$key" -noout > /dev/null 2>&1 || die "$key exists but is not a readable private key"
    echo "Reusing existing $name key (renewal). Use --rotate-keys to replace it."
  else
    tmpkey="$(mktemp "$PKI_DIR/.$name.key.XXXXXX")"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmpkey"
    chmod 0400 "$tmpkey"
    [ "$CHOWN" -eq 0 ] || chown "$owner" "$tmpkey"
    mv -f "$tmpkey" "$key"
    echo "Generated new $name key (owner $owner, mode 0400)."
    [ ! -f "$PKI_DIR/$name.crt" ] || echo "NOTE: the old $name.crt no longer matches this key; install the new certificate."
  fi
  cnf="$(mktemp "$PKI_DIR/.$name.cnf.XXXXXX")"
  cat > "$cnf" << CNF
[ req ]
distinguished_name = dn
prompt = no
string_mask = utf8only
[ dn ]
CN = $cn
OU = $GEN
CNF
  rm -f "$csr"
  openssl req -new -key "$key" -config "$cnf" -sha256 -out "$csr"
  rm -f "$cnf"
  chmod 0644 "$csr"
  echo "CSR: $csr  subject: CN=$cn OU=$GEN  pubkey-sha256: $(openssl req -in "$csr" -noout -pubkey | openssl sha256 | awk '{print $NF}')"
}

make_identity traefik home-lab-pi-traefik 10001:10001
make_identity host home-lab-pi-host 0:0

echo
echo "Copy these two CSRs (public data) to the laptop and sign them with scripts/pki/sign.sh."
for name in traefik host; do
  echo
  echo "===== $name.csr ====="
  cat "$PKI_DIR/$name.csr"
done
