#!/usr/bin/env bash
# s17-identity-tests.sh - Pi, root: negative and positive tests of the two Roles Anywhere identities (plan S17).
#
# Usage: sudo scripts/s17-identity-tests.sh
#
# Uses real session credentials from each certificate and prints API OUTCOMES only (never values, never credentials):
#   pi-host role (host cert)  : read /home-lab/* works; /not-home-lab denied; PutParameter denied; route53 denied;
#                               direct kms:Decrypt denied (only allowed via SSM).
#   ACME role (traefik cert)  : SSM denied; kms:Decrypt denied; may list records in the zone; may NOT change a
#                               non-_acme-challenge record (probed with a DELETE of a name that does not exist, so a
#                               misconfigured policy cannot create anything).
#   Mounts                    : no running container mounts the host key; the traefik key only in ra-helper.
# The revocation test (bump pki_generation, old certs fail) is manual: see docs/runbooks/m2-pi-setup.md.
# Needs the certificates, /etc/home-lab/aws.env and a successful fetch-secrets.sh run (for runtime.env).
set -uo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
require_root "$@"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
APPS_ROOT="$(lab_env_get "$REPO_DIR/config/lab.env" APPS_ROOT /apps)"
ETC=/etc/home-lab
AWS_ENV="$ETC/aws.env"
RUNTIME_ENV="$APPS_ROOT/secrets/runtime.env"
[ -f "$AWS_ENV" ] && [ -f "$RUNTIME_ENV" ] || die "need $AWS_ENV and $RUNTIME_ENV (run fetch-secrets.sh first)"

TA="$(lab_env_get "$AWS_ENV" RA_TRUST_ANCHOR_ARN)"
HOST_PROFILE="$(lab_env_get "$AWS_ENV" RA_HOST_PROFILE_ARN)"
HOST_ROLE="$(lab_env_get "$AWS_ENV" RA_HOST_ROLE_ARN)"
ACME_PROFILE="$(lab_env_get "$RUNTIME_ENV" RA_ACME_PROFILE_ARN)"
ACME_ROLE="$(lab_env_get "$RUNTIME_ENV" RA_ACME_ROLE_ARN)"
ZONE="$(lab_env_get "$RUNTIME_ENV" ROUTE53_ZONE_ID)"
DOMAIN="$(lab_env_get "$RUNTIME_ENV" DOMAIN)"
REGION="$(lab_env_get "$AWS_ENV" AWS_REGION af-south-1)"
for v in TA HOST_PROFILE HOST_ROLE ACME_PROFILE ACME_ROLE ZONE DOMAIN; do
  [ -n "${!v}" ] || die "$v is empty (check aws.env and runtime.env)"
done

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
helper=/usr/local/bin/aws_signing_helper
cat > "$W/config" << CFG
[profile s17-host]
region = $REGION
credential_process = $helper credential-process --certificate $ETC/pki/host.crt --private-key $ETC/pki/host.key --trust-anchor-arn $TA --profile-arn $HOST_PROFILE --role-arn $HOST_ROLE
[profile s17-acme]
region = us-east-1
credential_process = $helper credential-process --certificate $ETC/pki/traefik.crt --private-key $ETC/pki/traefik.key --trust-anchor-arn $TA --profile-arn $ACME_PROFILE --role-arn $ACME_ROLE
CFG
cat > "$W/probe.json" << PROBE
{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"s17-probe.$DOMAIN.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\"s17\""}]}}]}
PROBE

fails=0
ok() { printf '[PASS] %s\n' "$1"; }
bad() {
  printf '[FAIL] %s\n' "$1"
  fails=$((fails + 1))
}
awsp() { # awsp <profile> <aws args...>; stdout -> $W/out, stderr -> $W/err, returns aws exit code
  local p="$1"
  shift
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN AWS_CONFIG_FILE="$W/config" \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" \
    aws --profile "$p" --no-cli-pager "$@" > "$W/out" 2> "$W/err"
}
denied() { grep -qE 'AccessDenied|not authorized' "$W/err"; }
expect_allowed() { # <label> <profile> <aws args...>
  local label="$1" p="$2"
  shift 2
  if awsp "$p" "$@"; then ok "$label: allowed"; else bad "$label: expected success ($(grep -oE '[A-Za-z]+Exception|AccessDenied[A-Za-z]*|InvalidClient[A-Za-z]*' "$W/err" | head -n 1))"; fi
}
expect_denied() { # <label> <profile> <aws args...>
  local label="$1" p="$2"
  shift 2
  if awsp "$p" "$@"; then
    bad "$label: SUCCEEDED but must be denied"
  elif denied; then
    ok "$label: AccessDenied"
  else
    bad "$label: failed, but not with AccessDenied ($(grep -oE '[A-Za-z]+Exception' "$W/err" | head -n 1))"
  fi
}

echo "== pi-host role (host certificate)"
expect_allowed "ssm get-parameter /home-lab/authentik/secret-key with decryption" s17-host \
  ssm get-parameter --name /home-lab/authentik/secret-key --with-decryption --query Parameter.Version --output text
expect_denied "ssm get-parameter outside /home-lab" s17-host ssm get-parameter --name /not-home-lab/x --query Parameter.Version --output text
expect_denied "ssm put-parameter (probe name)" s17-host \
  ssm put-parameter --name /home-lab/s17-denied-probe --type String --value probe --overwrite
if awsp s17-host ssm get-parameter --name /home-lab/s17-denied-probe --query Parameter.Name --output text 2> /dev/null; then
  echo "       WARNING: /home-lab/s17-denied-probe exists; the put was NOT denied. Delete it and fix the role policy."
fi
expect_denied "route53 list-hosted-zones" s17-host route53 list-hosted-zones
# A made-up ciphertext fails with InvalidCiphertextException before KMS checks permissions, so the direct-decrypt probes use
# a real SecureString ciphertext (read without decryption) and SSM's encryption context; only kms:ViaService then decides.
if awsp s17-host ssm get-parameter --name /home-lab/authentik/secret-key --query 'Parameter.[Value,ARN]' --output text; then
  cut -f1 "$W/out" | base64 -d > "$W/real.bin"
  PARAM_ARN="$(cut -f2 "$W/out")"
else
  bad "read the SecureString ciphertext for the KMS probes ($(grep -oE '[A-Za-z]+Exception|AccessDenied[A-Za-z]*' "$W/err" | head -n 1))"
  PARAM_ARN=unknown
fi
expect_denied "kms decrypt called directly (not via SSM)" s17-host \
  kms decrypt --ciphertext-blob "fileb://$W/real.bin" --encryption-context "PARAMETER_ARN=$PARAM_ARN"

echo "== ACME role (traefik certificate)"
expect_denied "ssm get-parameter" s17-acme ssm get-parameter --name /home-lab/authentik/secret-key --query Parameter.Version --output text
expect_denied "kms decrypt called directly" s17-acme \
  kms decrypt --ciphertext-blob "fileb://$W/real.bin" --encryption-context "PARAMETER_ARN=$PARAM_ARN" --region "$REGION"
# No --query here: with --max-items the CLI applies a query to the trailing NextToken page too, and length(null) fails.
expect_allowed "route53 list-resource-record-sets in the zone" s17-acme \
  route53 list-resource-record-sets --hosted-zone-id "$ZONE" --max-items 1 --output json
expect_denied "route53 change of a non-_acme-challenge record" s17-acme \
  route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "file://$W/probe.json"

echo "== container mounts"
if command -v docker > /dev/null 2>&1; then
  mounts="$(docker ps -q | xargs -r docker inspect --format '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' 2> /dev/null || true)"
  if printf '%s\n' "$mounts" | grep -q "$ETC/pki/host.key"; then
    bad "a running container mounts the host key"
  else
    ok "no running container mounts the host key"
  fi
  if printf '%s\n' "$mounts" | grep "$ETC/pki/traefik.key" | grep -qv 'ra-helper'; then
    bad "the traefik key is mounted in a container other than ra-helper"
  else
    ok "the traefik key is not mounted outside ra-helper"
  fi
else
  bad "docker not available to inspect mounts"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "S17: all identity checks passed"
else
  echo "S17: $fails check(s) FAILED"
  exit 1
fi
