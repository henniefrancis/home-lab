#!/usr/bin/env bash
# test-ca-restore.sh - OWNER LAPTOP (Git Bash or WSL): prove that a RESTORED copy of the offline CA still works (K5).
#
# Usage: scripts/pki/test-ca-restore.sh --ca-dir DIR [--passfile FILE]
#   --ca-dir DIR     the restored CA directory: ca.key, ca.crt and issued.tsv (copied back from the password manager attachment or the USB stick)
#   --passfile FILE  read the key passphrase from FILE (automated tests only; normally you are prompted and nothing is echoed)
#
# What it checks, in order, and prints PASS or FAIL for each (final line: RESULT: PASS or RESULT: FAIL; exit 0 or 1):
#   1. ca.key, ca.crt and issued.tsv are there; ca.crt is the home-lab CA (CN=home-lab-offline-ca) and is not expired; ca.key is encrypted.
#   2. The passphrase decrypts ca.key, and ca.crt and ca.key are a pair (the public keys are identical).
#   3. The CA can still SIGN: a throwaway key and CSR with a distinct CN (home-lab-restore-test-<random>) are signed with the same
#      extensions as a real Pi certificate (pki/openssl-leaf.cnf), and the new certificate verifies against ca.crt for client authentication.
# Safety: the real CA directory is only READ. Its files are checksummed before and after and the run FAILS if anything changed (so
# issued.tsv is not touched: sign.sh is NOT used because it appends to it). The decrypted key is never written anywhere: openssl reads the
# encrypted ca.key and the passphrase from an environment variable of that one command (never on a command line, never echoed). The only files
# written are the throwaway key, CSR and certificate, in a 0700 mktemp directory that is removed on exit. The throwaway certificate is
# worthless: its CN matches no Roles Anywhere trust policy.
# Prints the SHA-256 of the three files so you can compare them with the live CA (a backup that differs from the live files is out of date).
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEAF_CNF="$SCRIPT_DIR/../../pki/openssl-leaf.cnf"
CA_DIR="" PASSFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ca-dir)
      CA_DIR="${2:?--ca-dir needs a directory}"
      shift 2
      ;;
    --passfile)
      PASSFILE="${2:?--passfile needs a file}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
[ -n "$CA_DIR" ] || {
  sed -n '2,5p' "$0" >&2
  exit 2
}
[ -d "$CA_DIR" ] || {
  echo "not a directory: $CA_DIR" >&2
  exit 2
}
command -v openssl > /dev/null || {
  echo "openssl not found" >&2
  exit 2
}
[ -f "$LEAF_CNF" ] || {
  echo "missing $LEAF_CNF" >&2
  exit 2
}

fails=0
pass() { printf '[PASS] %s\n' "$*"; }
failx() {
  printf '[FAIL] %s\n' "$*"
  fails=$((fails + 1))
}
warnx() { printf '[WARN] %s\n' "$*"; }

TMP=""
CA_PASS=""
# shellcheck disable=SC2317,SC2329 # run by the EXIT trap
cleanup() {
  CA_PASS=""
  [ -z "$TMP" ] || rm -rf "$TMP"
}
trap cleanup EXIT
TMP="$(mktemp -d)"
chmod 0700 "$TMP"

# manifest <dir>: every file below it with its SHA-256, sorted, plus the file count (detects a changed, added or removed file).
# It FAILS (non-zero, message on stderr) when any file cannot be read or nothing is found: an empty manifest before and after would
# otherwise compare equal and report "unchanged" for a directory that was never really checked (QA L-1, SEC L-4).
manifest() {
  local out
  out="$(cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

if ! before="$(manifest "$CA_DIR")"; then
  printf '[FAIL] cannot checksum every file in %s (an unreadable file, or an empty directory): fix the permissions and run again\n' "$CA_DIR"
  echo "RESULT: FAIL (the directory could not be checksummed, so \"unchanged\" could not be proved)"
  exit 1
fi

# ---------------------------------------------------------------- 1. files and certificate
for f in ca.key ca.crt; do
  if [ -f "$CA_DIR/$f" ]; then pass "$f is present"; else failx "$f is missing from $CA_DIR"; fi
done
if [ -f "$CA_DIR/issued.tsv" ]; then
  pass "issued.tsv is present ($(wc -l < "$CA_DIR/issued.tsv" | tr -d ' ') issuance rows; last: $(tail -n 1 "$CA_DIR/issued.tsv" | cut -f1-3 | tr '\t' ' '))"
else
  warnx "issued.tsv is missing: the CA works without it, but the record of issued certificates is lost (restore it from the backup)"
fi
if [ ! -f "$CA_DIR/ca.key" ] || [ ! -f "$CA_DIR/ca.crt" ]; then
  echo "RESULT: FAIL (the CA key or certificate is missing; nothing more can be checked)"
  exit 1
fi

if ! openssl x509 -in "$CA_DIR/ca.crt" -noout > /dev/null 2>&1; then
  failx "ca.crt is not a readable certificate (damaged, empty or not PEM): the copy is unusable"
else
  if ca_subj="$(openssl x509 -in "$CA_DIR/ca.crt" -noout -subject -nameopt RFC2253 2> /dev/null | sed 's/^subject=//')" && [ "$ca_subj" = "CN=home-lab-offline-ca" ]; then
    pass "ca.crt subject is CN=home-lab-offline-ca"
  else
    failx "ca.crt is not the home-lab CA certificate (subject: '${ca_subj:-unreadable}')"
  fi
  if openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend 0 > /dev/null 2>&1; then
    if openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend $((180 * 86400)) > /dev/null 2>&1; then
      pass "ca.crt is valid; $(openssl x509 -in "$CA_DIR/ca.crt" -noout -enddate | cut -d= -f2)"
    else
      warnx "ca.crt expires within 180 days ($(openssl x509 -in "$CA_DIR/ca.crt" -noout -enddate | cut -d= -f2)): plan the CA rotation now (every Pi certificate must be re-issued)"
    fi
  else
    failx "ca.crt has EXPIRED"
  fi
fi
echo "       ca.crt SHA-256 fingerprint: $(openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha256 2> /dev/null | cut -d= -f2) (compare with the trust anchor's certificate)"
if head -n 1 "$CA_DIR/ca.key" | grep -q 'ENCRYPTED PRIVATE KEY'; then
  pass "ca.key is passphrase-encrypted"
else
  warnx "ca.key is NOT encrypted (or not a PKCS#8 encrypted key): a copy that is readable without a passphrase must not leave the laptop"
fi
for f in ca.key ca.crt issued.tsv; do
  [ -f "$CA_DIR/$f" ] && echo "       sha256 $f: $(sha256sum "$CA_DIR/$f" | cut -d' ' -f1)"
done

# ---------------------------------------------------------------- 2. the passphrase and the key pair
if [ -n "$PASSFILE" ]; then
  [ -f "$PASSFILE" ] || {
    echo "passphrase file not found: $PASSFILE" >&2
    exit 2
  }
  CA_PASS="$(head -n 1 "$PASSFILE" | tr -d '\r')"
else
  { : < /dev/tty; } 2> /dev/null || {
    echo "no terminal to ask for the passphrase on (use --passfile only for tests)" >&2
    exit 2
  }
  # The prompt and the typed text go through the terminal, not through stdout; nothing is echoed.
  IFS= read -rs -p "CA key passphrase (not shown): " CA_PASS < /dev/tty > /dev/tty 2>&1 || true
  printf '\n' > /dev/tty
fi
export_pass() { HL_CA_TEST_PASS="$CA_PASS" "$@"; } # the passphrase only ever sits in the environment of ONE openssl command

if key_pub="$(export_pass openssl pkey -in "$CA_DIR/ca.key" -passin env:HL_CA_TEST_PASS -pubout 2> /dev/null)" && [ -n "$key_pub" ]; then
  pass "the passphrase decrypts ca.key"
  crt_pub="$(openssl x509 -in "$CA_DIR/ca.crt" -noout -pubkey 2> /dev/null || true)"
  if [ -n "$crt_pub" ] && [ "$key_pub" = "$crt_pub" ]; then
    pass "ca.crt and ca.key are a pair (public keys identical)"
  else
    failx "ca.crt and ca.key are NOT a pair: the backup mixes files from two different CAs"
  fi
else
  failx "the passphrase does not decrypt ca.key (wrong passphrase, or the key file is damaged)"
fi

# ---------------------------------------------------------------- 3. sign a throwaway CSR and verify the chain
if [ "$fails" -eq 0 ]; then
  cn="home-lab-restore-test-$(openssl rand -hex 6)"
  printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n' "$cn" > "$TMP/csr.cnf"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TMP/throwaway.key" 2> /dev/null
  openssl req -new -key "$TMP/throwaway.key" -config "$TMP/csr.cnf" -out "$TMP/throwaway.csr" 2> /dev/null
  if export_pass openssl x509 -req -in "$TMP/throwaway.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -passin env:HL_CA_TEST_PASS \
    -set_serial "0x01$(openssl rand -hex 15)" -days 1 -sha256 -extfile "$LEAF_CNF" -extensions leaf_ext -out "$TMP/throwaway.crt" 2> /dev/null; then
    pass "the CA signed a throwaway certificate (CN=$cn, valid 1 day)"
    if openssl verify -CAfile "$CA_DIR/ca.crt" -purpose sslclient "$TMP/throwaway.crt" > /dev/null 2>&1; then
      pass "the throwaway certificate verifies against ca.crt for client authentication (the chain works)"
    else
      failx "the throwaway certificate does NOT verify against ca.crt"
    fi
    if [ "$(openssl x509 -in "$TMP/throwaway.crt" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')" = "CN=home-lab-offline-ca" ]; then
      pass "its issuer is CN=home-lab-offline-ca"
    else
      failx "its issuer is not CN=home-lab-offline-ca"
    fi
  else
    failx "the CA could not sign the throwaway CSR"
  fi
else
  warnx "skipping the signing test because an earlier check failed"
fi

# ---------------------------------------------------------------- 4. the real CA directory must be untouched
if after="$(manifest "$CA_DIR")" && [ "$before" = "$after" ]; then
  pass "the CA directory is unchanged (every file checksummed before and after; issued.tsv untouched)"
else
  failx "THE CA DIRECTORY CHANGED DURING THE TEST: do not use this copy until you know why"
fi
rm -rf "$TMP"
TMP=""

if [ "$fails" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
fi
echo "RESULT: FAIL ($fails check(s) failed)"
exit 1
