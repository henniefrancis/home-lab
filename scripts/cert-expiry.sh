#!/usr/bin/env bash
# cert-expiry.sh - Pi: report the days left on the two Roles Anywhere certificates.
# Exit 0 = both valid for more than 30 days, 1 = a cert expires within 30 days, 2 = missing, unreadable or expired.
# Needs root to read /etc/home-lab/pki. Prints dates only, never key material.
set -euo pipefail

PKI_DIR="${HOME_LAB_PKI_DIR:-/etc/home-lab/pki}"
WARN_DAYS=30
rc=0

for name in traefik host; do
  crt="$PKI_DIR/$name.crt"
  if [ ! -r "$crt" ]; then
    echo "[FAIL] $name.crt: missing or unreadable (run as root?)"
    rc=2
    continue
  fi
  if ! openssl x509 -in "$crt" -noout -checkend 0 > /dev/null 2>&1; then
    echo "[FAIL] $name.crt: EXPIRED"
    rc=2
    continue
  fi
  end="$(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)"
  secs="$(( $(date -d "$end" +%s) - $(date +%s) ))"
  days="$((secs / 86400))"
  if [ "$days" -lt "$WARN_DAYS" ]; then
    echo "[WARN] $name.crt: expires in $days days ($end); reissue (docs/runbooks/m2-pi-setup.md, renewal)"
    [ "$rc" -eq 2 ] || rc=1
  else
    echo "[PASS] $name.crt: $days days left ($end)"
  fi
done
exit "$rc"
