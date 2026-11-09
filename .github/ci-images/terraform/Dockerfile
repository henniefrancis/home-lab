# CI tool image: terraform (SEC-M5, SEC-M6). Nothing is ever built from this file: .github/workflows/*.yml and scripts/scan-images.sh read
# the pinned reference from it (awk on the FROM line), and Dependabot (package-ecosystem docker, one entry per directory under
# /.github/ci-images) proposes version and digest bumps. One image per directory on purpose: a registry that refuses Dependabot
# (the combined file failed with UNAUTHORIZED on hashicorp/terraform) then fails only its own job, not the other tools.
# The reference is tag@sha256 (the multi-arch index digest): a moved tag cannot change what CI executes.
FROM hashicorp/terraform:1.17.1@sha256:a5d5a5a892c98f60fcbfa81eac2a40fc19e7b3fa7719bccae10ff6111d22524a AS terraform
