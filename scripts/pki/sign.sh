#!/usr/bin/env bash
# sign.sh - OWNER LAPTOP: validate a Pi CSR and sign it with the offline CA.
#
# Usage: scripts/pki/sign.sh --ca-dir DIR --role traefik|host --csr FILE --out FILE
#                            [--generation gen-1] [--days 365] [--passfile FILE] [--force]
#
# The CSR must carry EXACTLY the subject the Roles Anywhere trust policies require, so a wrong CSR is refused:
#   --role traefik  ->  CN=home-lab-pi-traefik, OU=<generation>
#   --role host     ->  CN=home-lab-pi-host,    OU=<generation>
# plus a valid self-signature and an ECDSA P-256 key. Certificates are CA:false, digitalSignature, clientAuth,
# SHA-256, 365 days by default, with a random 127-bit serial. Each issuance is appended to DIR/issued.tsv.
# The CA key passphrase is prompted by openssl (--passfile is for automated tests only).
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEAF_CNF="$SCRIPT_DIR/../../pki/openssl-leaf.cnf"
CA_DIR="" ROLE="" CSR="" OUT="" PASSFILE="" FORCE=0
GEN="gen-1"
DAYS=365

while [ $# -gt 0 ]; do
  case "$1" in
    --ca-dir) CA_DIR="${2:?}"; shift 2 ;;
    --role) ROLE="${2:?}"; shift 2 ;;
    --csr) CSR="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --generation) GEN="${2:?}"; shift 2 ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    --passfile) PASSFILE="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
die() { echo "REFUSED: $*" >&2; exit 1; }

[ -n "$CA_DIR" ] && [ -n "$ROLE" ] && [ -n "$CSR" ] && [ -n "$OUT" ] || { sed -n '2,6p' "$0" >&2; exit 2; }
case "$ROLE" in
  traefik) CN="home-lab-pi-traefik" ;;
  host) CN="home-lab-pi-host" ;;
  *) die "--role must be traefik or host" ;;
esac
[[ "$GEN" =~ ^[A-Za-z0-9-]{1,32}$ ]] || die "--generation must be 1-32 letters, digits or hyphens (same rule as pki_generation)"
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] && [ "$DAYS" -le 400 ] || die "--days must be 1-400"
[ -f "$CA_DIR/ca.key" ] && [ -f "$CA_DIR/ca.crt" ] || die "no CA in $CA_DIR (ca.key and ca.crt expected)"
[ -f "$CSR" ] || die "CSR file not found: $CSR"
[ -f "$LEAF_CNF" ] || die "missing $LEAF_CNF"
if [ -e "$OUT" ] && [ "$FORCE" -ne 1 ]; then die "$OUT already exists (use --force to replace)"; fi

# Git Bash: openssl.exe needs a native path inside file: arguments (plain path arguments are converted by MSYS, these are not).
native_path() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf %s "$1"; fi; }

norm_subject() { # "OU=x,CN=y" in any order -> sorted, comma-joined
  sed 's/^subject=//' | tr -d ' ' | tr ',' '\n' | sort | paste -sd,
}

# 1. CSR self-signature
openssl req -in "$CSR" -noout -verify > /dev/null 2>&1 || die "CSR self-signature is invalid"
# 2. Key type: ECDSA P-256 only
csr_text="$(openssl req -in "$CSR" -noout -text)"
printf '%s' "$csr_text" | grep -qE 'ASN1 OID: prime256v1|NIST CURVE: P-256' || die "CSR key must be ECDSA P-256"
# 3. Exact subject
want="$(printf 'CN=%s\nOU=%s\n' "$CN" "$GEN" | sort | paste -sd,)"
have="$(openssl req -in "$CSR" -noout -subject -nameopt RFC2253 | norm_subject)"
[ "$have" = "$want" ] || die "CSR subject '$have' is not exactly '$want' (wrong role or generation; the trust policy would reject it)"
# 4. CA sanity
ca_subj="$(openssl x509 -in "$CA_DIR/ca.crt" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
[ "$ca_subj" = "CN=home-lab-offline-ca" ] || die "CA subject is '$ca_subj', expected CN=home-lab-offline-ca"
openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend $((DAYS * 86400)) > /dev/null || die "the CA certificate expires before the new certificate would"

pass_in=()
[ -z "$PASSFILE" ] || pass_in=(-passin "file:$(native_path "$PASSFILE")")
[ -n "$PASSFILE" ] || echo "Enter the CA key passphrase when asked."

serial="0x01$(openssl rand -hex 15)"
tmp="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
openssl x509 -req -in "$CSR" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" "${pass_in[@]}" \
  -set_serial "$serial" -days "$DAYS" -sha256 -extfile "$LEAF_CNF" -extensions leaf_ext -out "$tmp"

openssl verify -CAfile "$CA_DIR/ca.crt" -purpose sslclient "$tmp" > /dev/null || die "issued certificate failed chain verification"
mv -f "$tmp" "$OUT"
chmod 644 "$OUT" 2> /dev/null || true
trap - EXIT

fp="$(openssl x509 -in "$OUT" -noout -fingerprint -sha256 | cut -d= -f2)"
end="$(openssl x509 -in "$OUT" -noout -enddate | cut -d= -f2)"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$ROLE" "CN=$CN,OU=$GEN" "$serial" "$end" "$fp" >> "$CA_DIR/issued.tsv"

echo "Signed $ROLE certificate -> $OUT"
openssl x509 -in "$OUT" -noout -subject -issuer -serial -dates -fingerprint -sha256 -ext basicConstraints,keyUsage,extendedKeyUsage
echo "Chain verification: OK. Logged in $CA_DIR/issued.tsv."
