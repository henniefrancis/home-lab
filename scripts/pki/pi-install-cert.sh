#!/usr/bin/env bash
# pi-install-cert.sh - PI, root: validate a signed certificate and install it next to its key.
#
# Usage: sudo scripts/pki/pi-install-cert.sh <traefik|host> [FILE|-] [--generation gen-1] [--pki-dir DIR] [--no-chown]
#   FILE   a PEM file; omit or use "-" to paste the PEM on stdin (finish with Ctrl-D on an empty line).
#
# Refuses unless: it parses as a certificate and contains no private key; the subject is exactly
# CN=home-lab-pi-<role>, OU=<generation>; the issuer is exactly CN=home-lab-offline-ca; CA:false; digitalSignature;
# not expired; and the public key matches the local <role>.key. Installs <role>.crt as root:root 0444.
set -euo pipefail
umask 077

case "${1:-}" in
  -h | --help)
    sed -n '2,9p' "$0"
    exit 0
    ;;
esac
ROLE="${1:-}"
[ $# -eq 0 ] || shift
SRC="-"
GEN="gen-1"
PKI_DIR="/etc/home-lab/pki"
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
    --no-chown)
      CHOWN=0
      shift
      ;;
    -h | --help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *)
      SRC="$1"
      shift
      ;;
  esac
done
die() {
  echo "REFUSED: $*" >&2
  exit 1
}

case "$ROLE" in
  traefik) CN="home-lab-pi-traefik" ;;
  host) CN="home-lab-pi-host" ;;
  *)
    sed -n '2,5p' "$0" >&2
    exit 2
    ;;
esac
[[ "$GEN" =~ ^[A-Za-z0-9-]{1,32}$ ]] || die "--generation must be 1-32 letters, digits or hyphens"
if [ "$CHOWN" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then die "run as root: sudo $0 ..."; fi
KEY="$PKI_DIR/$ROLE.key"
[ -f "$KEY" ] || die "$KEY missing; run pi-csr.sh first"

tmp="$(mktemp -d "$PKI_DIR/.install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
if [ "$SRC" = "-" ]; then
  echo "Paste the certificate PEM, then press Ctrl-D on an empty line."
  cat > "$tmp/in.pem"
else
  [ -f "$SRC" ] || die "file not found: $SRC"
  cat "$SRC" > "$tmp/in.pem"
fi
if grep -q 'PRIVATE KEY' "$tmp/in.pem"; then die "the input contains a private key; certificates only"; fi
openssl x509 -in "$tmp/in.pem" -out "$tmp/cert.pem" 2> /dev/null || die "input is not a valid PEM certificate"

norm() { sed 's/^[a-z]*=//' | tr -d ' ' | tr ',' '\n' | sort | paste -sd,; }
have_subj="$(openssl x509 -in "$tmp/cert.pem" -noout -subject -nameopt RFC2253 | norm)"
want_subj="$(printf 'CN=%s\nOU=%s\n' "$CN" "$GEN" | sort | paste -sd,)"
[ "$have_subj" = "$want_subj" ] || die "subject '$have_subj' is not exactly '$want_subj'"
[ "$(openssl x509 -in "$tmp/cert.pem" -noout -issuer -nameopt RFC2253 | norm)" = "CN=home-lab-offline-ca" ] || die "issuer is not exactly CN=home-lab-offline-ca"
text="$(openssl x509 -in "$tmp/cert.pem" -noout -text)"
printf '%s' "$text" | grep -q 'CA:FALSE' || die "certificate is not CA:FALSE"
printf '%s' "$text" | grep -q 'Digital Signature' || die "certificate lacks the digitalSignature key usage"
openssl x509 -in "$tmp/cert.pem" -noout -checkend 0 > /dev/null || die "certificate is expired"
# -checkend does not detect a certificate that is not yet valid. The Pi has no RTC: a wrong clock after a power cut lands here.
not_before="$(date -d "$(openssl x509 -in "$tmp/cert.pem" -noout -startdate | cut -d= -f2)" +%s)" || die "cannot read the certificate start date"
[ "$not_before" -le "$(date +%s)" ] || die "certificate is not valid yet (notBefore is in the future): check the Pi clock with timedatectl"
cert_pub="$(openssl x509 -in "$tmp/cert.pem" -noout -pubkey | openssl sha256 | awk '{print $NF}')"
key_pub="$(openssl pkey -in "$KEY" -pubout | openssl sha256 | awk '{print $NF}')"
[ "$cert_pub" = "$key_pub" ] || die "certificate public key does not match $KEY (wrong CSR, or the key was rotated)"
if ! openssl x509 -in "$tmp/cert.pem" -noout -checkend $((30 * 86400)) > /dev/null; then
  echo "WARN: this certificate expires in under 30 days."
fi

if [ "$CHOWN" -eq 1 ]; then
  install -m 0444 -o root -g root "$tmp/cert.pem" "$PKI_DIR/$ROLE.crt"
else
  install -m 0444 "$tmp/cert.pem" "$PKI_DIR/$ROLE.crt"
fi
echo "Installed $PKI_DIR/$ROLE.crt"
openssl x509 -in "$PKI_DIR/$ROLE.crt" -noout -subject -issuer -dates -fingerprint -sha256
