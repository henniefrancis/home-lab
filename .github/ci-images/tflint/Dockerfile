# CI tool image: tflint (SEC-M5, SEC-M6). Nothing is ever built from this file: .github/workflows/*.yml and scripts/scan-images.sh read
# the pinned reference from it (awk on the FROM line), and Dependabot (package-ecosystem docker, one entry per directory under
# /.github/ci-images) proposes version and digest bumps. One image per directory on purpose: a registry that refuses Dependabot
# (the combined file failed with UNAUTHORIZED on hashicorp/terraform) then fails only its own job, not the other tools.
# The reference is tag@sha256 (the multi-arch index digest): a moved tag cannot change what CI executes.
FROM ghcr.io/terraform-linters/tflint:v0.65.0@sha256:2788f4d4fc663c0e953b011b01bf443fe5bfce7587ee916e588e6057b85d6359 AS tflint
