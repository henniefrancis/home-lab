#!/usr/bin/env bash
# scan-images.sh - OWNER LAPTOP or any Docker host: scan every third-party image pinned in the compose files with Trivy (SEC-M5).
#
# Usage: scripts/scan-images.sh [--fail-on-fixed-critical] [--severity HIGH,CRITICAL]
#   default       prints HIGH and CRITICAL findings that have a fixed version (--ignore-unfixed); exit 0
#   --fail-on-fixed-critical   exit 1 when a CRITICAL with a fix exists in any image (use it before a bump PR is merged)
# On demand, not in CI: the Authentik image alone is several hundred MB, which does not fit the 5 minute CI budget. Run it after
# every Dependabot image PR and about monthly. The Trivy image is the digest-pinned one from ci/images/trivy/Dockerfile. Needs docker
# and network access to the registries and the Trivy vulnerability database; it never sends your code anywhere.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
export MSYS_NO_PATHCONV=1

SEVERITY="HIGH,CRITICAL"
FAIL_CRIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fail-on-fixed-critical)
      FAIL_CRIT=1
      shift
      ;;
    --severity)
      [ $# -ge 2 ] || {
        echo "--severity needs a value" >&2
        exit 2
      }
      SEVERITY="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
command -v docker > /dev/null || {
  echo "docker is required" >&2
  exit 2
}
trivy_img="$(awk '$1=="FROM" && $4=="trivy" {print $2}' ci/images/trivy/Dockerfile)"
[ -n "$trivy_img" ] || {
  echo "no trivy image in ci/images/trivy/Dockerfile" >&2
  exit 2
}

# Pulled images from the compose files, plus the runtime base images of the two locally built ones (ra-helper, it-tools). The
# it-tools "AS app" stage is left out on purpose: only its static files are copied into our image, none of its packages ship.
images="$({
  grep -hE '^[[:space:]]+image:[[:space:]]' traefik/compose.yaml authentik/compose.yaml homepage/compose.yaml tailscale/compose.yaml it-tools/compose.yaml |
    awk '{print $2}'
  grep -hE '^FROM ' traefik/ra-helper/Dockerfile it-tools/Dockerfile | grep -v ' AS app$' | awk '{print $2}'
} | grep '@sha256:' | sort -u)"
[ -n "$images" ] || {
  echo "no pinned images found" >&2
  exit 2
}
echo "Trivy image: $trivy_img"
rc=0
for img in $images; do
  echo
  echo "=== $img"
  docker run --rm -v trivy-cache:/root/.cache "$trivy_img" image --quiet --ignore-unfixed --severity "$SEVERITY" "$img" || true
  if [ "$FAIL_CRIT" -eq 1 ]; then
    docker run --rm -v trivy-cache:/root/.cache "$trivy_img" image --quiet --ignore-unfixed --severity CRITICAL --exit-code 1 "$img" > /dev/null 2>&1 || {
      echo "CRITICAL with a fix: $img"
      rc=1
    }
  fi
done
exit "$rc"
