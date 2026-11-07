#!/usr/bin/env bash
# new-ca.sh - OWNER LAPTOP (Git Bash or WSL): create the offline home-lab CA.
#
# Usage: scripts/pki/new-ca.sh [--out DIR] [--passfile FILE]
#   --out DIR        where to create the CA (default: ~/home-lab-ca). MUST be outside the repository.
#   --passfile FILE  read the key passphrase from FILE (for automated tests only; normally openssl prompts).
#
# Creates ca.key (ECDSA P-384, encrypted with a passphrase you choose) and ca.crt (CN home-lab-offline-ca, 5 years).
# The CA key never leaves this machine: store ca.key AND its passphrase in the password manager, then keep ca.key
# only on encrypted storage. Only ca.crt (public) is pasted into the HCP variable ca_cert_pem.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_CNF="$SCRIPT_DIR/../../pki/openssl-ca.cnf"
OUT="${HOME}/home-lab-ca"
PASSFILE=""
DAYS=1826 # 5 years

while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      OUT="${2:?--out needs a directory}"
      shift 2
      ;;
    --passfile)
      PASSFILE="${2:?--passfile needs a file}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,11p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# Git Bash: openssl.exe needs a native path inside file: arguments (plain path arguments are converted by MSYS, these are not).
native_path() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf %s "$1"; fi; }

command -v openssl > /dev/null || {
  echo "openssl not found" >&2
  exit 1
}
[ -f "$CA_CNF" ] || {
  echo "missing $CA_CNF" >&2
  exit 1
}

mkdir -p "$OUT"
chmod 700 "$OUT" 2> /dev/null || true
if git -C "$OUT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "Refusing: $OUT is inside a git work tree. The CA must live outside any repository." >&2
  exit 1
fi
if [ -e "$OUT/ca.key" ] || [ -e "$OUT/ca.crt" ]; then
  echo "Refusing: $OUT already contains a CA. Never overwrite it; choose another --out." >&2
  exit 1
fi

pass_out=()
pass_in=()
if [ -n "$PASSFILE" ]; then
  pass_out=(-pass "file:$(native_path "$PASSFILE")")
  pass_in=(-passin "file:$(native_path "$PASSFILE")")
else
  echo "You will be asked for a NEW passphrase for the CA key (twice), then once more to sign the CA certificate."
  echo "Generate it in the password manager first and paste it; it is never shown or stored by this script."
fi

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -aes-256-cbc "${pass_out[@]}" -out "$OUT/ca.key"
chmod 400 "$OUT/ca.key" 2> /dev/null || true
openssl req -x509 -new -key "$OUT/ca.key" "${pass_in[@]}" -sha384 -days "$DAYS" -config "$CA_CNF" -out "$OUT/ca.crt"

echo
echo "CA created in: $OUT"
openssl x509 -in "$OUT/ca.crt" -noout -subject -issuer -dates -fingerprint -sha256
echo
echo "NEXT:"
echo "  1. Store $OUT/ca.key and its passphrase in the password manager (attach the file, keep the passphrase as a separate field)."
echo "  2. Paste the PUBLIC certificate below into the HCP workspace variable ca_cert_pem (or: cat $OUT/ca.crt)."
echo
cat "$OUT/ca.crt"
