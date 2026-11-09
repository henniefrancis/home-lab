#!/usr/bin/env bash
# test-pki.sh - self-test of the PKI scripts in a temp dir (no root, no network, no real keys).
# Runs the whole flow (CA -> Pi CSRs -> sign -> install) and the refusal cases, and test-ca-restore.sh (K5) against a restored copy of the
# throwaway CA, including the cases that must fail (wrong passphrase, mismatched pair, missing or damaged key). Used by CI.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pki" "$T/ca-parent"
printf 'test-passphrase-not-secret\n' > "$T/pass"
fails=0
ok() { echo "ok   - $1"; }
bad() {
  echo "FAIL - $1"
  fails=$((fails + 1))
}
expect_ok() {
  local n="$1"
  shift
  if "$@" > "$T/out.log" 2>&1; then
    ok "$n"
  else
    bad "$n"
    sed 's/^/       /' "$T/out.log"
  fi
}
expect_refused() {
  local n="$1"
  shift
  if "$@" > "$T/out.log" 2>&1; then bad "$n (was accepted)"; else ok "$n"; fi
}

CA="$T/ca-parent/ca"
expect_ok "new-ca creates the CA" "$HERE/new-ca.sh" --out "$CA" --passfile "$T/pass"
expect_refused "new-ca refuses to overwrite" "$HERE/new-ca.sh" --out "$CA" --passfile "$T/pass"
if [ "$(openssl x509 -in "$CA/ca.crt" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')" = "CN=home-lab-offline-ca" ]; then ok "CA subject"; else bad "CA subject"; fi
if openssl x509 -in "$CA/ca.crt" -noout -text | grep -q 'CA:TRUE'; then ok "CA is CA:TRUE"; else bad "CA is CA:TRUE"; fi
if head -n 1 "$CA/ca.key" | grep -q 'ENCRYPTED PRIVATE KEY'; then ok "CA key is encrypted"; else bad "CA key is encrypted"; fi

PI=(--pki-dir "$T/pki" --no-chown)
expect_ok "pi-csr generates keys and CSRs" "$HERE/pi-csr.sh" "${PI[@]}"
if grep -q 'PRIVATE KEY' "$T/out.log"; then bad "pi-csr printed key material"; else ok "pi-csr output has no key material"; fi
expect_ok "pi-csr is repeatable (reuses keys)" "$HERE/pi-csr.sh" "${PI[@]}"
for n in traefik host; do
  if [ "$(uname -o)" = Msys ]; then
    ok "$n.key mode check skipped (Windows file system)"
  elif [ "$(stat -c '%a' "$T/pki/$n.key")" = 400 ]; then ok "$n.key mode 0400"; else bad "$n.key mode"; fi
done

S=(--ca-dir "$CA" --passfile "$T/pass")
expect_ok "sign host" "$HERE/sign.sh" "${S[@]}" --role host --csr "$T/pki/host.csr" --out "$T/host.crt"
expect_ok "sign traefik" "$HERE/sign.sh" "${S[@]}" --role traefik --csr "$T/pki/traefik.csr" --out "$T/traefik.crt"
expect_refused "sign refuses role/CN mismatch" "$HERE/sign.sh" "${S[@]}" --role traefik --csr "$T/pki/host.csr" --out "$T/x1.crt"
expect_refused "sign refuses wrong generation" "$HERE/sign.sh" "${S[@]}" --role host --generation gen-2 --csr "$T/pki/host.csr" --out "$T/x2.crt"
expect_refused "sign refuses to overwrite output" "$HERE/sign.sh" "${S[@]}" --role host --csr "$T/pki/host.csr" --out "$T/host.crt"
if [ "$(wc -l < "$CA/issued.tsv" | tr -d ' ')" = 2 ]; then ok "issuance log has 2 rows"; else bad "issuance log"; fi
if openssl x509 -in "$T/host.crt" -noout -text | grep -q 'CA:FALSE'; then ok "leaf is CA:FALSE"; else bad "leaf is CA:FALSE"; fi
if openssl x509 -in "$T/host.crt" -noout -text | grep -q 'TLS Web Client Authentication'; then ok "leaf has clientAuth"; else bad "leaf clientAuth"; fi

# Bad CSRs: RSA key, extra RDN, tampered signature
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$T/rsa.key" 2> /dev/null
printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=home-lab-pi-host\nOU=gen-1\n' > "$T/ok.cnf"
printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=home-lab-pi-host\nOU=gen-1\nO=extra\n' > "$T/extra.cnf"
openssl req -new -key "$T/rsa.key" -config "$T/ok.cnf" -out "$T/rsa.csr"
expect_refused "sign refuses RSA CSR" "$HERE/sign.sh" "${S[@]}" --role host --csr "$T/rsa.csr" --out "$T/x3.crt"
openssl req -new -key "$T/pki/host.key" -config "$T/extra.cnf" -out "$T/extra.csr"
expect_refused "sign refuses extra subject fields" "$HERE/sign.sh" "${S[@]}" --role host --csr "$T/extra.csr" --out "$T/x4.crt"
sed '5s/./A/;6s/./B/' "$T/pki/host.csr" > "$T/tampered.csr"
expect_refused "sign refuses a tampered CSR" "$HERE/sign.sh" "${S[@]}" --role host --csr "$T/tampered.csr" --out "$T/x5.crt"

# Install on the Pi side
expect_ok "install host cert" "$HERE/pi-install-cert.sh" host "$T/host.crt" "${PI[@]}"
expect_ok "install traefik cert (stdin)" bash -c "'$HERE/pi-install-cert.sh' traefik --pki-dir '$T/pki' --no-chown < '$T/traefik.crt'"
expect_refused "install refuses host cert as traefik" "$HERE/pi-install-cert.sh" traefik "$T/host.crt" "${PI[@]}"
expect_refused "install refuses wrong generation" "$HERE/pi-install-cert.sh" host "$T/host.crt" --generation gen-2 "${PI[@]}"
cat "$T/host.crt" "$T/pki/host.key" > "$T/withkey.pem"
expect_refused "install refuses input with a private key" "$HERE/pi-install-cert.sh" host "$T/withkey.pem" "${PI[@]}"

# Foreign CA: same subject and key, different issuer -> install must refuse (issuer check)
printf '[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=some-other-ca
[ext]
basicConstraints=critical,CA:true
keyUsage=critical,keyCertSign
' > "$T/fca.cnf"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$T/fca.key" -config "$T/fca.cnf" -days 30 -out "$T/fca.crt" 2> /dev/null
openssl x509 -req -in "$T/pki/host.csr" -CA "$T/fca.crt" -CAkey "$T/fca.key" -set_serial 0x0102 -days 30 -sha256   -extfile "$HERE/../../pki/openssl-leaf.cnf" -extensions leaf_ext -out "$T/foreign.crt" 2> /dev/null
expect_refused "install refuses a cert from another CA" "$HERE/pi-install-cert.sh" host "$T/foreign.crt" "${PI[@]}"

# A rotated key must not accept the old certificate
expect_ok "pi-csr --rotate-keys" "$HERE/pi-csr.sh" "${PI[@]}" --rotate-keys
expect_refused "install refuses a cert that does not match the rotated key" "$HERE/pi-install-cert.sh" host "$T/host.crt" "${PI[@]}"

# CA restore test (K5): test-ca-restore.sh against a restored copy of the throwaway CA, and the cases that must FAIL.
RT="$HERE/test-ca-restore.sh"
sha_tree() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }
cp -r "$CA" "$T/restore"
before_tree="$(sha_tree "$T/restore")"
mkdir -p "$T/rt-tmp"
if TMPDIR="$T/rt-tmp" "$RT" --ca-dir "$T/restore" --passfile "$T/pass" > "$T/out.log" 2>&1; then ok "test-ca-restore passes on a restored copy"; else bad "test-ca-restore passes on a restored copy"; sed 's/^/       /' "$T/out.log"; fi
if grep -q '^RESULT: PASS' "$T/out.log" && grep -q 'the chain works' "$T/out.log" && grep -q 'ca.crt and ca.key are a pair' "$T/out.log"; then ok "test-ca-restore reports the pair check, the signing test and the chain"; else bad "test-ca-restore reports"; fi
if [ "$before_tree" = "$(sha_tree "$T/restore")" ]; then ok "test-ca-restore left the CA directory byte-for-byte unchanged (issued.tsv too)"; else bad "test-ca-restore changed the CA directory"; fi
if [ "$(wc -l < "$T/restore/issued.tsv" | tr -d ' ')" = 2 ]; then ok "issued.tsv still has exactly the 2 real rows (the throwaway certificate was not logged)"; else bad "issued.tsv row count changed"; fi
if [ -z "$(ls -A "$T/rt-tmp")" ]; then ok "test-ca-restore removed its temporary directory (throwaway key included)"; else bad "test-ca-restore left files in its temp dir"; fi
if grep -Eq 'test-passphrase-not-secret|PRIVATE KEY' "$T/out.log"; then bad "test-ca-restore printed the passphrase or key material"; else ok "test-ca-restore output has no passphrase and no key material"; fi
if grep -q 'home-lab-restore-test-' "$T/out.log"; then ok "the throwaway certificate has a distinct CN (home-lab-restore-test-...)"; else bad "throwaway CN"; fi

printf 'wrong-passphrase\n' > "$T/badpass"
if "$RT" --ca-dir "$T/restore" --passfile "$T/badpass" > "$T/out.log" 2>&1; then bad "test-ca-restore accepted a wrong passphrase"; else ok "test-ca-restore fails on a wrong passphrase"; fi
if grep -q 'does not decrypt ca.key' "$T/out.log" && grep -q '^RESULT: FAIL' "$T/out.log" && ! grep -q 'wrong-passphrase' "$T/out.log"; then ok "...says so, prints FAIL and does not echo the passphrase"; else bad "wrong passphrase message"; fi
if [ "$before_tree" = "$(sha_tree "$T/restore")" ]; then ok "...and the CA directory is still unchanged after a failed run"; else bad "CA dir changed after a failed run"; fi

# a backup that mixes two CAs (certificate of another CA with this key)
"$HERE/new-ca.sh" --out "$T/ca-other" --passfile "$T/pass" > /dev/null 2>&1
mkdir "$T/mixed" && cp "$CA/ca.key" "$T/mixed/ca.key" && cp "$T/ca-other/ca.crt" "$T/mixed/ca.crt" && cp "$CA/issued.tsv" "$T/mixed/"
if "$RT" --ca-dir "$T/mixed" --passfile "$T/pass" > "$T/out.log" 2>&1; then bad "test-ca-restore accepted a certificate that does not match the key"; else ok "test-ca-restore fails when ca.crt and ca.key are not a pair"; fi
if grep -q 'NOT a pair' "$T/out.log"; then ok "...and names the mismatch"; else bad "mismatch message"; fi

# missing key, damaged key, foreign CA subject, missing issued.tsv (warning only)
mkdir "$T/nokey" && cp "$CA/ca.crt" "$CA/issued.tsv" "$T/nokey/"
if "$RT" --ca-dir "$T/nokey" --passfile "$T/pass" > "$T/out.log" 2>&1; then bad "test-ca-restore accepted a CA directory without ca.key"; else ok "test-ca-restore fails when ca.key is missing"; fi
mkdir "$T/damaged" && cp "$CA/ca.crt" "$CA/issued.tsv" "$T/damaged/" && head -c 200 "$CA/ca.key" > "$T/damaged/ca.key"
if "$RT" --ca-dir "$T/damaged" --passfile "$T/pass" > "$T/out.log" 2>&1; then bad "test-ca-restore accepted a truncated ca.key"; else ok "test-ca-restore fails on a damaged ca.key"; fi
mkdir "$T/foreign" && cp "$T/fca.crt" "$T/foreign/ca.crt" && cp "$T/fca.key" "$T/foreign/ca.key"
if "$RT" --ca-dir "$T/foreign" --passfile "$T/pass" > "$T/out.log" 2>&1; then bad "test-ca-restore accepted a CA that is not the home-lab CA"; else ok "test-ca-restore fails when the subject is not CN=home-lab-offline-ca"; fi
if grep -q 'not the home-lab CA certificate' "$T/out.log" && grep -q 'is NOT encrypted' "$T/out.log"; then ok "...and warns that an unencrypted key copy is a risk"; else bad "foreign CA messages"; fi
mkdir "$T/noissued" && cp "$CA/ca.key" "$CA/ca.crt" "$T/noissued/"
if "$RT" --ca-dir "$T/noissued" --passfile "$T/pass" > "$T/out.log" 2>&1 && grep -q 'issued.tsv is missing' "$T/out.log"; then ok "a missing issued.tsv is a warning, not a failure (the CA still works)"; else bad "missing issued.tsv handling"; fi
if "$RT" --ca-dir "$T/does-not-exist" --passfile "$T/pass" > "$T/out.log" 2>&1; then bad "test-ca-restore accepted a missing directory"; else ok "test-ca-restore refuses a directory that does not exist"; fi
if "$RT" --passfile "$T/pass" > "$T/out.log" 2>&1; then bad "test-ca-restore ran without --ca-dir"; else ok "test-ca-restore needs --ca-dir"; fi

# QA L-1 / L-2 / L-3, SEC L-4: an unreadable file must FAIL loudly, a garbage certificate is "not readable" (not "expired"), and no terminal is rc 2
if [ "$(id -u)" -ne 0 ] && [ "$(uname -o)" != Msys ]; then
  mkdir "$T/unreadable" && cp "$CA/ca.key" "$CA/ca.crt" "$CA/issued.tsv" "$T/unreadable/" && chmod 000 "$T/unreadable/issued.tsv"
  if "$RT" --ca-dir "$T/unreadable" --passfile "$T/pass" > "$T/out.log" 2>&1; then bad "test-ca-restore accepted a directory with an unreadable file"; else ok "test-ca-restore fails when a file cannot be read"; fi
  if grep -q 'cannot checksum every file' "$T/out.log" && grep -q '^RESULT: FAIL' "$T/out.log"; then ok "...with a clear message and RESULT: FAIL (not a silent exit)"; else bad "unreadable-file message"; fi
  chmod 600 "$T/unreadable/issued.tsv"
else
  ok "unreadable-file case skipped (root or Windows can read everything)"
fi
mkdir "$T/garbage" && cp "$CA/ca.key" "$CA/issued.tsv" "$T/garbage/" && printf 'not a certificate\n' > "$T/garbage/ca.crt"
if "$RT" --ca-dir "$T/garbage" --passfile "$T/pass" > "$T/out.log" 2>&1; then bad "test-ca-restore accepted a garbage ca.crt"; else ok "test-ca-restore fails on a garbage ca.crt"; fi
if grep -q 'not a readable certificate' "$T/out.log" && ! grep -q 'EXPIRED' "$T/out.log"; then ok "...and says it is unreadable, not expired"; else bad "garbage ca.crt message"; fi
if command -v setsid > /dev/null 2>&1; then
  if setsid "$RT" --ca-dir "$T/restore" > "$T/out.log" 2>&1 < /dev/null; rc=$?; [ "$rc" -eq 2 ] && grep -q 'no terminal' "$T/out.log"; then ok "no terminal and no --passfile: a clear message and exit 2"; else bad "no terminal handling (rc=$rc)"; fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "PKI self-test: all checks passed"
else
  echo "PKI self-test: $fails FAILED"
  exit 1
fi
