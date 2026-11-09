#!/usr/bin/env bash
# test-terraform-policies.sh - offline assertions on the IAM and KMS policies of terraform/bootstrap (SEC-H1, SEC-M1, SEC-M2).
# Copies the stack to a temporary directory (no real terraform.tfvars, no HCP backend, no state), swaps the provider configuration for a stub with
# fake credentials and skipped validation, and runs `terraform test` (tests/policies.tftest.hcl) with a dead HTTPS proxy: nothing can reach AWS.
# Needs terraform >= 1.7. TERRAFORM overrides the binary.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
TF="${TERRAFORM:-terraform}"
command -v "$TF" > /dev/null || {
  echo "terraform is required" >&2
  exit 2
}
work="$(mktemp -d)"
# Cleanup must not turn a passing run red (files written by a containerised terraform may not be removable by this user).
trap 'rm -rf "$work" 2> /dev/null || true' EXIT
mkdir "$work/tests"
cp terraform/bootstrap/*.tf terraform/bootstrap/.terraform.lock.hcl "$work/"
cp terraform/bootstrap/tests/*.tftest.hcl "$work/tests/"
cat > "$work/providers.tf" << 'PROVIDERS'
locals {
  tags = {}
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

provider "aws" {
  alias                       = "af_south_1"
  region                      = "af-south-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
PROVIDERS
# the HCP backend does not belong in an offline test
awk 'BEGIN{skip=0} /^  cloud \{/{skip=1} skip==0{print} skip==1 && /^  \}/{skip=0}' "$work/versions.tf" > "$work/versions.tf.new" && mv "$work/versions.tf.new" "$work/versions.tf"
unset AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
export TF_IN_AUTOMATION=1 TF_INPUT=0
(cd "$work" && "$TF" init -backend=false -input=false -no-color > /dev/null)
# From here on, any attempt to open a connection goes to a closed local port.
export HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=
(cd "$work" && "$TF" test -no-color)
