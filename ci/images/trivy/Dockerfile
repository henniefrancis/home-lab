# CI tool image: trivy (SEC-M5, SEC-M6). Nothing is ever built from this file: .github/workflows/*.yml and scripts/scan-images.sh read
# the pinned reference from it (awk on the FROM line), and Dependabot (package-ecosystem docker, one entry per directory under
# /ci/images) proposes version and digest bumps. One image per directory on purpose: a registry that refuses Dependabot
# (the combined file failed with UNAUTHORIZED on hashicorp/terraform) then fails only its own job, not the other tools.
# The reference is tag@sha256 (the multi-arch index digest): a moved tag cannot change what CI executes.
FROM ghcr.io/aquasecurity/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb AS trivy
