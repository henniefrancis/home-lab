# CI tool image: gitleaks (SEC-M5, SEC-M6). Nothing is ever built from this file: .github/workflows/*.yml and scripts/scan-images.sh read
# the pinned reference from it (awk on the FROM line), and Dependabot (package-ecosystem docker, one entry per directory under
# /.github/ci-images) proposes version and digest bumps. One image per directory on purpose: a registry that refuses Dependabot
# (the combined file failed with UNAUTHORIZED on hashicorp/terraform) then fails only its own job, not the other tools.
# The reference is tag@sha256 (the multi-arch index digest): a moved tag cannot change what CI executes.
FROM ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f AS gitleaks
