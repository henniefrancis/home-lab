#!/usr/bin/env bash
# deploy.sh - Pi, root: update the checkout, refresh secrets from SSM, then start the stack.
#
# Usage: sudo scripts/deploy.sh [--offline] [--no-git] [--only <stack>]
#   --offline      skip the SSM fetch and the image pull; start from the last-good secrets (power cut with no internet).
#                  Without this flag a failed fetch aborts the deploy (the existing secrets stay in place).
#   --no-git       do not run git pull.
#   --only <stack> deploy one stack directory only, e.g. --only tailscale (uses <stack>/compose.yaml).
#                  Without it, the root compose.yaml is used once it exists (milestone M3 onwards).
#
# Skeleton for milestone M2 (plan 6.10): git pull --ff-only, fetch-secrets, compose pull and up, health summary,
# certificate expiry. It never writes inside the repo checkout except through git.
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"
APPS_ROOT="$(lab_env_get "$LAB_ENV" APPS_ROOT /apps)"

OFFLINE=0
NO_GIT=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --offline)
      OFFLINE=1
      shift
      ;;
    --no-git)
      NO_GIT=1
      shift
      ;;
    --only)
      ONLY="${2:?--only needs a stack name}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done
require_root "$@"
[[ -z "$ONLY" || "$ONLY" =~ ^[a-z0-9-]+$ ]] || die "--only expects a plain directory name"

echo "== 1/4 git"
if [ "$NO_GIT" -eq 1 ]; then
  echo "skipped (--no-git)"
elif [ "$OFFLINE" -eq 1 ]; then
  echo "skipped (--offline)"
elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  sudo -u "$SUDO_USER" git -C "$REPO_DIR" pull --ff-only
else
  git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" pull --ff-only
fi

echo "== 2/4 secrets"
if [ "$OFFLINE" -eq 1 ]; then
  [ -f "$APPS_ROOT/secrets/runtime.env" ] || die "--offline needs existing secrets, but $APPS_ROOT/secrets/runtime.env is missing"
  warn "OFFLINE: using the last-good secrets in $APPS_ROOT/secrets"
else
  "$SCRIPT_DIR/fetch-secrets.sh" || die "secret fetch failed; nothing was started. Use --offline only to boot from the last-good secrets."
fi

echo "== 3/4 compose"
if [ -n "$ONLY" ]; then
  COMPOSE_FILE="$REPO_DIR/$ONLY/compose.yaml"
else
  COMPOSE_FILE="$REPO_DIR/compose.yaml"
fi
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "No $COMPOSE_FILE yet (the root compose.yaml arrives with milestone M3); secrets are refreshed, nothing to start."
else
  dc() { docker compose -f "$COMPOSE_FILE" --env-file "$LAB_ENV" --env-file "$APPS_ROOT/secrets/runtime.env" "$@"; }
  [ "$OFFLINE" -eq 1 ] || dc pull
  dc up -d --remove-orphans
  echo
  dc ps --format 'table {{.Name}}\t{{.Status}}'
fi

echo "== 4/4 certificate expiry"
"$SCRIPT_DIR/cert-expiry.sh" || true
echo "deploy finished"
