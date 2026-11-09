#!/usr/bin/env bash
# served-cert-check.sh - Pi: check the certificate Traefik ACTUALLY SERVES for the wildcard (K4), not the Roles Anywhere certificates.
# Connects to 127.0.0.1:443 with SNI dashboard.<DOMAIN> (DOMAIN from $APPS_ROOT/secrets/runtime.env; override with SERVED_CERT_HOST).
# Prints one [PASS], [WARN] or [FAIL] line (dates and issuer only). Exit 0 = ok, 1 = fewer than SERVED_CERT_WARN_DAYS (default 21)
# days left, 2 = expired, within SERVED_CERT_CRIT_DAYS (default 7), or not valid for the host (for example Traefik's default
# self-signed certificate), 3 = no TLS answer. Run by scripts/alert.sh check (daily timer) and scripts/preflight.sh. Needs root only to read runtime.env.
# Test overrides: HOME_LAB_SERVED_ADDR (host:port, default 127.0.0.1:443).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"
APPS_ROOT="$(lab_env_get "$LAB_ENV" APPS_ROOT /apps)"
ADDR="${HOME_LAB_SERVED_ADDR:-127.0.0.1:443}"
WARN_DAYS="${SERVED_CERT_WARN_DAYS:-21}"
CRIT_DAYS="${SERVED_CERT_CRIT_DAYS:-7}"
{ [[ "$WARN_DAYS" =~ ^[0-9]+$ ]] && [[ "$CRIT_DAYS" =~ ^[0-9]+$ ]]; } || die "SERVED_CERT_WARN_DAYS and SERVED_CERT_CRIT_DAYS must be whole numbers"

HOST="${SERVED_CERT_HOST:-}"
if [ -z "$HOST" ]; then
  domain="$(lab_env_get "$APPS_ROOT/secrets/runtime.env" DOMAIN)"
  [ -n "$domain" ] || {
    echo "[FAIL] served-cert: cannot read DOMAIN from $APPS_ROOT/secrets/runtime.env (run as root after a deploy), or set SERVED_CERT_HOST"
    exit 2
  }
  HOST="dashboard.$domain"
fi
[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "bad host name for the served-cert check"
command -v openssl > /dev/null || die "openssl not installed"

pem="$(printf '' | timeout 15 openssl s_client -connect "$ADDR" -servername "$HOST" 2> /dev/null | openssl x509 2> /dev/null || true)"
if [ -z "$pem" ]; then
  echo "[FAIL] served-cert: no TLS certificate from $ADDR for $HOST (is Traefik running? docker compose ps)"
  exit 3
fi
end="$(printf '%s\n' "$pem" | openssl x509 -noout -enddate | cut -d= -f2)"
issuer="$(printf '%s\n' "$pem" | openssl x509 -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//' | grep -o 'CN=[^,]*' | head -n 1 || true)"
if ! printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 > /dev/null 2>&1; then
  echo "[FAIL] served-cert: the certificate served for $HOST is EXPIRED ($end, ${issuer:-unknown issuer})"
  exit 2
fi
if ! printf '%s\n' "$pem" | openssl x509 -noout -checkhost "$HOST" 2> /dev/null | grep -q 'does match'; then
  echo "[FAIL] served-cert: the certificate served for $HOST does not cover that name (Traefik default certificate? ${issuer:-unknown issuer}, expires $end)"
  exit 2
fi
days="$((($(date -d "$end" +%s) - $(date +%s)) / 86400))"
if [ "$days" -lt "$CRIT_DAYS" ]; then
  echo "[FAIL] served-cert: $HOST certificate expires in $days days ($end, ${issuer:-unknown issuer}); renewal is not happening (docs/runbooks/alerting.md)"
  exit 2
elif [ "$days" -lt "$WARN_DAYS" ]; then
  echo "[WARN] served-cert: $HOST certificate expires in $days days ($end, ${issuer:-unknown issuer}); Traefik should renew at 30 days (docs/runbooks/alerting.md)"
  exit 1
fi
echo "[PASS] served-cert: $HOST certificate has $days days left ($end, ${issuer:-unknown issuer})"
