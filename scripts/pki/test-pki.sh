#!/usr/bin/env bash
# test-pki.sh - self-test of the PKI scripts in a temp dir (no root, no network, no real keys).
# Runs the whole flow (CA -> Pi CSRs -> sign -> install) and the refusal cases. Used by CI.
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

echo
if [ "$fails" -eq 0 ]; then
  echo "PKI self-test: all checks passed"
else
  echo "PKI self-test: $fails FAILED"
  exit 1
fi
