#!/usr/bin/env bash
# render-aws-env.sh - OWNER LAPTOP: print the contents of the Pi's /etc/home-lab/aws.env (step U13) from terraform output.
#
# Usage: scripts/render-aws-env.sh [--generation gen-1] [--age-recipient age1...]
#   --age-recipient  the owner's age PUBLIC key for the Authentik backup (K5; from `age-keygen`, saved identity stays in the password manager).
#                    Printed as BACKUP_AGE_RECIPIENT; the bucket (BACKUP_S3_BUCKET) comes from the terraform output backup_bucket_name.
#
# Reads the outputs of terraform/bootstrap (the identity stack, SEC-H1). Prints five KEY=VALUE lines (plus ALERT_TOPIC_ARN, K4, BACKUP_S3_BUCKET and BACKUP_AGE_RECIPIENT, K5, once the stack with those resources is applied) to stdout (nothing is written to disk). The values identify the AWS account, so they are
# never committed: paste them into the Pi shell as shown in docs/runbooks/m2-pi-setup.md. Needs `terraform login` and
# TF_CLOUD_ORGANIZATION (see docs/runbooks/hcp-terraform-bootstrap.md); it only reads outputs from HCP state.
set -euo pipefail

GEN="gen-1"
AGE_RECIPIENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --generation)
      GEN="${2:?}"
      shift 2
      ;;
    --age-recipient)
      AGE_RECIPIENT="${2:?--age-recipient needs an age public key (age1...)}"
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
[[ "$GEN" =~ ^[A-Za-z0-9-]{1,32}$ ]] || {
  echo "--generation must be 1-32 letters, digits or hyphens" >&2
  exit 2
}

# The recipient is public by design, but a typo makes every backup unreadable: refuse anything that is not an age X25519 public key
# (age1 plus 58 bech32 characters). An identity (AGE-SECRET-KEY-...) is refused loudly, so a private key is never pasted into aws.env.
if [ -n "$AGE_RECIPIENT" ] && ! [[ "$AGE_RECIPIENT" =~ ^age1[02-9ac-hj-np-z]{58}$ ]]; then
  echo "--age-recipient must be an age public key (age1 and 58 more characters). Never pass the secret identity (AGE-SECRET-KEY-...)." >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$HERE/../terraform/bootstrap"
out() { terraform -chdir="$TF_DIR" output -raw "$1" 2> /dev/null | tr -d '\r'; }

ta="$(out trust_anchor_arn || true)"
profile="$(out host_profile_arn || true)"
role="$(out host_role_arn || true)"
alert_topic="$(out alert_topic_arn || true)"
backup_bucket="$(out backup_bucket_name || true)"
[[ "$ta" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:trust-anchor/[0-9a-f-]+$ ]] || {
  echo "trust_anchor_arn output missing: has the owner applied terraform/bootstrap with ca_cert_pem set? Is 'terraform init' done there?" >&2
  exit 1
}
[[ "$profile" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:profile/[0-9a-f-]+$ ]] || {
  echo "host_profile_arn output missing or malformed" >&2
  exit 1
}
[[ "$role" =~ ^arn:aws[a-z-]*:iam::[0-9]+:role/[A-Za-z0-9+=,.@_/-]+$ ]] || {
  echo "host_role_arn output missing or malformed" >&2
  exit 1
}

printf 'AWS_REGION=af-south-1\n'
printf 'PKI_GENERATION=%s\n' "$GEN"
printf 'RA_TRUST_ANCHOR_ARN=%s\n' "$ta"
printf 'RA_HOST_PROFILE_ARN=%s\n' "$profile"
printf 'RA_HOST_ROLE_ARN=%s\n' "$role"
# K4: the SNS alert topic (scripts/alert.sh). Optional until terraform/bootstrap with alerts.tf has been applied.
if [[ "$alert_topic" =~ ^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$ ]]; then
  printf 'ALERT_TOPIC_ARN=%s\n' "$alert_topic"
else
  echo "note: no alert_topic_arn output yet (apply terraform/bootstrap with alert_email set); ALERT_TOPIC_ARN not printed" >&2
fi
# K5: the Authentik backup (scripts/backup-authentik.sh). The bucket is a terraform output; the recipient is the owner's public key.
if [[ "$backup_bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  printf 'BACKUP_S3_BUCKET=%s\n' "$backup_bucket"
else
  echo "note: no backup_bucket_name output yet (apply terraform/bootstrap with backup.tf); BACKUP_S3_BUCKET not printed" >&2
fi
if [ -n "$AGE_RECIPIENT" ]; then
  printf 'BACKUP_AGE_RECIPIENT=%s\n' "$AGE_RECIPIENT"
else
  echo "note: no --age-recipient given; BACKUP_AGE_RECIPIENT not printed (docs/runbooks/authentik-backup.md, owner setup)" >&2
fi
