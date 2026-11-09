#!/usr/bin/env bash
# served-cert-check.sh - Pi: check the certificate Traefik ACTUALLY SERVES for the wildcard (K4), not the Roles Anywhere certificates.
# Connects to 127.0.0.1:443 with SNI dashboard.<DOMAIN> (DOMAIN from $APPS_ROOT/secrets/runtime.env; override with SERVED_CERT_HOST).
# Checks: a certificate is served, it is valid now (not expired, not "not valid yet"), it covers the host name, enough days are left,
# and the issuer matches the environment config/lab.env asks for (ACME_CA_SERVER): production must chain to a publicly trusted root and
# must not be a staging certificate; staging should be a staging one (QA-M-1).
# Prints one [PASS], [WARN] or [FAIL] line (dates and issuer only). Exit codes:
#   0 ok | 1 fewer than SERVED_CERT_WARN_DAYS (default 21) days left, or the issuer is not the staging CA while staging is configured
#   2 expired, not valid yet, within SERVED_CERT_CRIT_DAYS (default 7), not valid for the host (e.g. Traefik's default self-signed
#     certificate), or a staging or untrusted certificate while production is configured
#   3 no TLS answer | 4 this check could not run (bad setting, openssl missing): a problem with the check, not with the certificate
# Run by scripts/alert.sh check (daily timer) and scripts/preflight.sh. Needs root only to read runtime.env.
# Overrides (tests): HOME_LAB_SERVED_ADDR (host:port, default 127.0.0.1:443), SERVED_CERT_EXPECT (prod, staging or any),
# SERVED_CERT_CAFILE (trust store for the chain check; default: the system store).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

crash() {
  echo "[FAIL] served-cert: the check could not run: $*"
  exit 4
}

REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"
APPS_ROOT="$(lab_env_get "$LAB_ENV" APPS_ROOT /apps)"
ADDR="${HOME_LAB_SERVED_ADDR:-127.0.0.1:443}"
WARN_DAYS="${SERVED_CERT_WARN_DAYS:-21}"
CRIT_DAYS="${SERVED_CERT_CRIT_DAYS:-7}"
{ [[ "$WARN_DAYS" =~ ^[0-9]+$ ]] && [[ "$CRIT_DAYS" =~ ^[0-9]+$ ]]; } || crash "SERVED_CERT_WARN_DAYS and SERVED_CERT_CRIT_DAYS must be whole numbers"
command -v openssl > /dev/null || crash "openssl is not installed"

EXPECT="${SERVED_CERT_EXPECT:-}"
if [ -z "$EXPECT" ]; then
  case "$(lab_env_get "$LAB_ENV" ACME_CA_SERVER | tr -d ' "'"'")" in
    https://acme-v02.api.letsencrypt.org/directory) EXPECT=prod ;;
    https://acme-staging-v02.api.letsencrypt.org/directory) EXPECT=staging ;;
    *) EXPECT=any ;;
  esac
fi
case "$EXPECT" in prod | staging | any) ;; *) crash "SERVED_CERT_EXPECT must be prod, staging or any" ;; esac

HOST="${SERVED_CERT_HOST:-}"
if [ -z "$HOST" ]; then
  domain="$(lab_env_get "$APPS_ROOT/secrets/runtime.env" DOMAIN)"
  [ -n "$domain" ] || crash "cannot read DOMAIN from $APPS_ROOT/secrets/runtime.env (run as root after a deploy), or set SERVED_CERT_HOST"
  HOST="dashboard.$domain"
fi
[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || crash "bad host name"

cafile=()
[ -z "${SERVED_CERT_CAFILE:-}" ] || cafile=(-CAfile "$SERVED_CERT_CAFILE")
raw="$(printf '' | timeout 15 openssl s_client -connect "$ADDR" -servername "$HOST" -verify_hostname "$HOST" "${cafile[@]}" 2> /dev/null || true)"
pem="$(printf '%s\n' "$raw" | openssl x509 2> /dev/null || true)"
if [ -z "$pem" ]; then
  echo "[FAIL] served-cert: no TLS certificate from $ADDR for $HOST (is Traefik running? docker compose ps)"
  exit 3
fi
end="$(printf '%s\n' "$pem" | openssl x509 -noout -enddate | cut -d= -f2)"
start="$(printf '%s\n' "$pem" | openssl x509 -noout -startdate | cut -d= -f2)"
issuer="$(printf '%s\n' "$pem" | openssl x509 -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//' | grep -o 'CN=[^,]*' | head -n 1 || true)"
issuer="${issuer:-unknown issuer}"
if ! printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 > /dev/null 2>&1; then
  echo "[FAIL] served-cert: the certificate served for $HOST is EXPIRED ($end, $issuer)"
  exit 2
fi
# -checkend does not notice a certificate that is not valid yet (a Pi clock years behind, no RTC): fail, and name the clock.
if [ "$(date -d "$start" +%s)" -gt "$(date +%s)" ]; then
  echo "[FAIL] served-cert: the certificate served for $HOST is NOT VALID YET (notBefore $start is in the future): check the Pi clock (timedatectl) first"
  exit 2
fi
if ! printf '%s\n' "$pem" | openssl x509 -noout -checkhost "$HOST" 2> /dev/null | grep -q 'does match'; then
  echo "[FAIL] served-cert: the certificate served for $HOST does not cover that name (Traefik default certificate? $issuer, expires $end)"
  exit 2
fi
staging_like=0
printf '%s' "$issuer" | grep -qiE 'staging|fake' && staging_like=1
if [ "$EXPECT" = prod ]; then
  if [ "$staging_like" -eq 1 ]; then
    echo "[FAIL] served-cert: $HOST is served with a STAGING certificate ($issuer) but config/lab.env asks for production: browsers reject it (docs/runbooks/m6-go-live.md, step 1)"
    exit 2
  fi
  if ! printf '%s\n' "$raw" | grep -q 'Verify return code: 0 (ok)'; then
    echo "[FAIL] served-cert: the certificate served for $HOST ($issuer) does not chain to a trusted root (self-signed, or an incomplete chain)"
    exit 2
  fi
elif [ "$EXPECT" = staging ] && [ "$staging_like" -eq 0 ]; then
  echo "[WARN] served-cert: config/lab.env asks for the staging CA but $HOST is served by $issuer (expires $end)"
  exit 1
fi
days="$((($(date -d "$end" +%s) - $(date +%s)) / 86400))"
if [ "$days" -lt "$CRIT_DAYS" ]; then
  echo "[FAIL] served-cert: $HOST certificate expires in $days days ($end, $issuer); renewal is not happening (docs/runbooks/alerting.md)"
  exit 2
elif [ "$days" -lt "$WARN_DAYS" ]; then
  echo "[WARN] served-cert: $HOST certificate expires in $days days ($end, $issuer); Traefik should renew at 30 days (docs/runbooks/alerting.md)"
  exit 1
fi
echo "[PASS] served-cert: $HOST certificate has $days days left ($end, $issuer, $EXPECT)"
