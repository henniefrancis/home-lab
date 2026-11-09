# CI tool image: tflint (SEC-M5, SEC-M6). Nothing is ever built from this file: .github/workflows/*.yml and scripts/scan-images.sh read
# the pinned reference from it (awk on the FROM line), and Dependabot (package-ecosystem docker, one entry per directory under
# /ci/images) proposes version and digest bumps. One image per directory on purpose: a registry that refuses Dependabot
# (the combined file failed with UNAUTHORIZED on hashicorp/terraform) then fails only its own job, not the other tools.
# The reference is tag@sha256 (the multi-arch index digest): a moved tag cannot change what CI executes.
FROM ghcr.io/terraform-linters/tflint:v0.66.0@sha256:65b9944a9274c4989492c1d79998c2801664bf8a55fddb4bd3a9e6d73a006ddc AS tflint
