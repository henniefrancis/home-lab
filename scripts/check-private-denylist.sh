#!/usr/bin/env bash
# check-private-denylist.sh - scan the repository (every commit on every ref, which includes every file that would be public) for the owner's PRIVATE identifiers
# with gitleaks (N12). The public CI rules (.gitleaks.toml) already catch 12-digit account IDs and hosted zone IDs; this adds the things
# only the owner knows: the real domain, the Pi and tailnet addresses, personal e-mail addresses, the SSO role hash, the HCP organisation.
#
# Usage: scripts/check-private-denylist.sh [--config FILE] [--repo DIR]
#   --config FILE  the private rules (default: <repo>/.gitleaks-private.toml, GITIGNORED; copy .gitleaks-private.toml.example and fill it in)
#   --repo DIR     the repository to scan (default: the one this script lives in)
# Run it: before the repo goes public (against the exact commit that goes public), and optionally as a pre-push hook:
#   printf '#!/bin/sh\nexec bash scripts/check-private-denylist.sh\n' > .git/hooks/pre-push && chmod +x .git/hooks/pre-push
# CI never runs this and never sees the private file (it is not in git); CI uses the public rules only.
# Needs a gitleaks binary or docker (the digest-pinned image from ci/images/gitleaks/Dockerfile).
# Exit codes: 0 nothing found, 1 a private identifier was found, 2 not configured (no private file, still the template, no tool).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || {
        echo "--config needs a value" >&2
        exit 2
      }
      CONFIG="$2"
      shift 2
      ;;
    --repo)
      [ $# -ge 2 ] || {
        echo "--repo needs a value" >&2
        exit 2
      }
      REPO="$(cd "$2" && pwd)"
      shift 2
      ;;
    -h | --help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
[ -n "$CONFIG" ] || CONFIG="$REPO/.gitleaks-private.toml"

if [ ! -f "$CONFIG" ]; then
  echo "No private denylist at $CONFIG." >&2
  echo "Copy .gitleaks-private.toml.example to .gitleaks-private.toml (gitignored), put your real domain, addresses and e-mails in it, and run again." >&2
  exit 2
fi
if grep -q 'FILL-IN-BEFORE-USE' "$CONFIG"; then
  echo "$CONFIG still contains the template marker FILL-IN-BEFORE-USE: replace the placeholder patterns with your real values first." >&2
  exit 2
fi

native_path() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
export MSYS_NO_PATHCONV=1

run_gitleaks() { # run_gitleaks <git|dir>
  local mode="$1"
  if command -v gitleaks > /dev/null 2>&1; then
    gitleaks "$mode" "$REPO" --config "$CONFIG" --redact --no-banner
  elif command -v docker > /dev/null 2>&1; then
    local img cfgdir
    img="$(awk '$1=="FROM" && $4=="gitleaks" {print $2}' "$SCRIPT_DIR/../ci/images/gitleaks/Dockerfile")"
    [ -n "$img" ] || {
      echo "no gitleaks image in ci/images/gitleaks/Dockerfile" >&2
      exit 2
    }
    cfgdir="$(cd "$(dirname "$CONFIG")" && pwd)"
    docker run --rm -v "$(native_path "$REPO"):/repo:ro" -v "$(native_path "$cfgdir"):/cfg:ro" "$img" \
      "$mode" /repo --config "/cfg/$(basename "$CONFIG")" --redact --no-banner
  else
    echo "Neither gitleaks nor docker is available." >&2
    exit 2
  fi
}

rc=0
echo "== private denylist: every commit on every ref (untracked and ignored files are NOT scanned: they never become public)"
run_gitleaks git || rc=$?
case "$rc" in
  0) echo "No private identifier found." ;;
  1) echo "A private identifier was found (see above). Do not push or publish." >&2 ;;
  *) echo "gitleaks could not run (exit $rc)." >&2 ;;
esac
exit "$rc"
