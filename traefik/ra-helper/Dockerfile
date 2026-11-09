# ra-helper: IAM Roles Anywhere credential helper in `serve` mode (plan 6.2). It shares Traefik's network namespace and
# exposes an IMDSv2-compatible endpoint on 127.0.0.1:9911, which Traefik's AWS SDK uses through
# AWS_EC2_METADATA_SERVICE_ENDPOINT. The Traefik certificate key is mounted ONLY into this container, as a secret.
#
# The version and SHA256 below MUST equal HELPER_VERSION / HELPER_SHA256 in scripts/lib/pins.sh (CI checks this).
# Source of both: https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html (Linux, Aarch64 row).
# The build runs on the Pi (arm64), so the Aarch64 binary is the right one. `ADD --checksum` fails the build on mismatch.
# N8: nothing is installed at build time. The previous `apt-get install ca-certificates` made every deploy-time build depend on the
# Debian mirrors (a mutable input on the Pi). The CA bundle now comes from a digest-pinned Alpine image (Mozilla bundle, Go reads
# /etc/ssl/certs/ca-certificates.crt), and the final stage is a digest-pinned Debian slim (it only supplies bash for the healthcheck).
# Both FROM lines are multi-arch index digests that Dependabot bumps together; CI fails if a FROM is not pinned or if apt or apk appear here.
FROM alpine:3.22@sha256:bfe7ceb9f09ec0566c48fb93356e45a47a00be5a1dd14fa5b909e7709c66b034 AS certs
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

ARG HELPER_VERSION=1.8.6
ARG HELPER_SHA256=b8a1800a9f483674a376170e1eabc0796a4ad3b7ac048670de9346975e9925dc

COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

ADD --checksum=sha256:${HELPER_SHA256} --chmod=0555 \
    https://rolesanywhere.amazonaws.com/releases/${HELPER_VERSION}/Aarch64/Linux/Amzn2023/aws_signing_helper \
    /usr/local/bin/aws_signing_helper

LABEL org.opencontainers.image.title="ra-helper" \
      org.opencontainers.image.description="AWS IAM Roles Anywhere credential helper (serve mode)" \
      org.opencontainers.image.version="${HELPER_VERSION}"

USER 10001:10001
ENTRYPOINT ["/usr/local/bin/aws_signing_helper"]
