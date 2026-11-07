#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # the variables are used by the scripts that source this file
# Pinned third-party binaries for the Pi host. Source it; do not execute it.
#
# aws_signing_helper (IAM Roles Anywhere credential helper)
#   Download URL and SHA256 are copied from the official AWS user guide, "Credential helper tool":
#   https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html
#   (Linux, Aarch64 row; the page lists one SHA256 per download; version 1.8.6 released 2026-11-04.)
#   To bump: copy the new URL version and the Aarch64 SHA256 from that page, then update the ra-helper
#   image (traefik/ra-helper/Dockerfile, milestone M3) to the same version.
#   Note: docs/plan/phase-1-traefik.md rev 7 named 1.8.5; 1.8.6 supersedes it (security patches, serve hardening).
HELPER_VERSION="1.8.6"
HELPER_SHA256="b8a1800a9f483674a376170e1eabc0796a4ad3b7ac048670de9346975e9925dc"
HELPER_URL="https://rolesanywhere.amazonaws.com/releases/${HELPER_VERSION}/Aarch64/Linux/Amzn2023/aws_signing_helper"
HELPER_BIN="/usr/local/bin/aws_signing_helper"

# AWS CLI v2: latest official aarch64 installer, GPG-verified against the AWS CLI team key.
#   Installer and signature: https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip(.sig)
#   Key and fingerprint: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
#   The armored key is vendored in scripts/pubkeys/awscli-team.asc; bootstrap.sh checks this fingerprint.
#   The key expires 2027-07-01; after that AWS publishes a new key on the page above (update the file and fingerprint).
AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
# (spaced as printed on that page; scripts remove the spaces before comparing)
AWSCLI_KEY_FPR="FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C"
