# Single source of truth for the container images that CI runs with `docker run` (SEC-M5, SEC-M6). Nothing is ever built from
# this file: it exists so that (a) .github/workflows/*.yml read the pinned references from here (see the `img` helper there),
# and (b) Dependabot (package-ecosystem docker, directory /.github/ci-images) proposes version and digest bumps as pull requests.
# Every reference is tag@sha256 (the multi-arch index digest): a moved tag cannot change what CI executes.
FROM ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f AS gitleaks
FROM hashicorp/terraform:1.17.1@sha256:a5d5a5a892c98f60fcbfa81eac2a40fc19e7b3fa7719bccae10ff6111d22524a AS terraform
FROM ghcr.io/terraform-linters/tflint:v0.65.0@sha256:2788f4d4fc663c0e953b011b01bf443fe5bfce7587ee916e588e6057b85d6359 AS tflint
FROM ghcr.io/aquasecurity/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb AS trivy
