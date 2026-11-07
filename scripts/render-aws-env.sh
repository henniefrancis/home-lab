#!/usr/bin/env bash
# render-aws-env.sh - OWNER LAPTOP: print the contents of the Pi's /etc/home-lab/aws.env (step U13) from terraform output.
#
# Usage: scripts/render-aws-env.sh [--generation gen-1]
#
# Prints five KEY=VALUE lines to stdout (nothing is written to disk). The values identify the AWS account, so they are
# never committed: paste them into the Pi shell as shown in docs/runbooks/m2-pi-setup.md. Needs `terraform login` and
# TF_CLOUD_ORGANIZATION (see docs/runbooks/hcp-terraform-bootstrap.md); it only reads outputs from HCP state.
set -euo pipefail

GEN="gen-1"
while [ $# -gt 0 ]; do
  case "$1" in
    --generation)
      GEN="${2:?}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,8p' "$0"
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$HERE/../terraform/edge"
out() { terraform -chdir="$TF_DIR" output -raw "$1" 2> /dev/null | tr -d '\r'; }

ta="$(out trust_anchor_arn || true)"
profile="$(out host_profile_arn || true)"
role="$(out host_role_arn || true)"
[[ "$ta" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:trust-anchor/[0-9a-f-]+$ ]] || {
  echo "trust_anchor_arn output missing: has the lead applied Roles Anywhere (after ca_cert_pem was set)? Is 'terraform init' done in terraform/edge?" >&2
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
