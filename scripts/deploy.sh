#!/usr/bin/env bash
# deploy.sh - Pi, root: update the checkout, refresh secrets from SSM, then start the stack.
#
# Usage: sudo scripts/deploy.sh [--offline] [--no-git] [--only <stack> | --recreate <stack>]
#   --offline      skip the SSM fetch, the git fetch and the image pull; start from the last-good secrets (power cut with no
#                  internet). Without this flag a failed fetch aborts the deploy (the existing secrets stay in place).
#   --no-git       do not fetch or merge (the checked-out commit is still signature-verified).
#   --only <stack> deploy one stack directory only, e.g. --only tailscale (uses <stack>/compose.yaml; the directory must
#                  exist). Without it, the root compose.yaml (all stacks) is used. Both run as the same compose project
#                  ("home-lab"), so --only never removes the containers of the other stacks (no --remove-orphans).
#   --recreate <stack>  like --only <stack>, and also recreates every container of that stack (compose --force-recreate). Use it after
#                  a secret changed: fetch-secrets.sh replaces the secret files, but a running container keeps the file it was
#                  created with, and a plain deploy leaves unchanged containers alone (docs/runbooks/rotate-secrets.md).
# Exit codes: 0 ok, 1 failure, 2 usage error.
#
# Plan 6.10: git fetch, signature check, ff-only merge, fetch-secrets, compose build/pull/up, health summary, certificate
# expiry. SEC-M7: only a commit whose SSH signature verifies against /etc/home-lab/allowed_signers (outside the checkout, root
# owned) is ever merged or run; there is no bypass flag (fail closed). SEC-M3: the checkout is root-owned and this script
# runs git as root, so nobody who can log in can change a file that root executes: deploy.sh REFUSES to start unless the whole
# checkout (.git included) is root-owned and not writable by others, and it runs git with hooks disabled. It never writes inside the checkout
# except through git.
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/verify-commit.sh
. "$SCRIPT_DIR/lib/verify-commit.sh"
# shellcheck source=lib/units.sh
. "$SCRIPT_DIR/lib/units.sh"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"
APPS_ROOT="$(lab_env_get "$LAB_ENV" APPS_ROOT /apps)"
ALLOWED_SIGNERS="${HOME_LAB_ALLOWED_SIGNERS:-/etc/home-lab/allowed_signers}"
DYNAMIC_DIR="${TRAEFIK_DYNAMIC_DIR:-$APPS_ROOT/traefik/dynamic}"

usage_error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

OFFLINE=0
NO_GIT=0
ONLY=""
RECREATE=0
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
      [ $# -ge 2 ] && [ -n "$2" ] || usage_error "--only needs a stack name"
      [ "$RECREATE" -eq 0 ] || usage_error "--only and --recreate cannot be combined (--recreate already means --only for that stack)"
      [ -z "$ONLY" ] || usage_error "--only given twice"
      ONLY="$2"
      shift 2
      ;;
    --recreate)
      [ $# -ge 2 ] && [ -n "$2" ] || usage_error "--recreate needs a stack name"
      [ "$RECREATE" -eq 0 ] || usage_error "--recreate was given twice"
      [ -z "$ONLY" ] || usage_error "--only and --recreate cannot be combined (--recreate already means --only for that stack)"
      ONLY="$2"
      RECREATE=1
      shift 2
      ;;
    -h | --help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
# Argument validation comes before the root check, so a typo is reported as a typo (QA-L-6).
[[ -z "$ONLY" || "$ONLY" =~ ^[a-z0-9-]+$ ]] || usage_error "--only and --recreate expect a plain directory name"
[ -z "$ONLY" ] || [ -f "$REPO_DIR/$ONLY/compose.yaml" ] || usage_error "--only/--recreate $ONLY: there is no $ONLY/compose.yaml in the repository (QA-L-5)"
require_root "$@"

# NEW-1: root runs git and this checkout's scripts, so the whole tree (.git included) must be root-owned and not writable by others.
# This is checked BEFORE any git call, and git's own ownership guard is not bypassed (no safe.directory): a root-owned checkout needs
# none. Hooks are switched off for every git call made as root (defence in depth).
assert_root_tree "$REPO_DIR"

echo "== 1/4 git"
git_root() { git -c core.hooksPath=/dev/null -C "$REPO_DIR" "$@"; }
if [ "$NO_GIT" -eq 1 ]; then
  echo "fetch skipped (--no-git)"
elif [ "$OFFLINE" -eq 1 ]; then
  echo "fetch skipped (--offline)"
else
  branch="$(git_root symbolic-ref --quiet --short HEAD)" || die "the checkout is not on a branch; refusing to deploy"
  git_root fetch --quiet origin "$branch"
  # Verify the fetched tip BEFORE it touches the working tree, with the trust file from outside the checkout.
  verify_signed_commit "$REPO_DIR" FETCH_HEAD "$ALLOWED_SIGNERS" || die "the fetched commit is not signed by an allowed signer; nothing was merged"
  git_root merge --ff-only --quiet FETCH_HEAD
fi
verify_signed_commit "$REPO_DIR" HEAD "$ALLOWED_SIGNERS" || die "HEAD is not signed by an allowed signer; nothing was started"
echo "HEAD $(git_root rev-parse --short HEAD): signature verified against $ALLOWED_SIGNERS"

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
  echo "No $COMPOSE_FILE; secrets are refreshed, nothing to start."
else
  # Traefik's watched directory is a root-owned COPY of traefik/dynamic: only a deploy of a signed commit changes it. Each file
  # is written next to its target and renamed (atomic for the watcher); files that no longer exist in the repo are removed,
  # except the break-glass drop-in, which belongs to scripts/breakglass.sh.
  install -d -m 0755 -o root -g root "$DYNAMIC_DIR"
  for f in "$REPO_DIR"/traefik/dynamic/*.yml; do
    install -m 0644 -o root -g root "$f" "$DYNAMIC_DIR/.$(basename "$f").new"
    mv -f "$DYNAMIC_DIR/.$(basename "$f").new" "$DYNAMIC_DIR/$(basename "$f")"
  done
  for f in "$DYNAMIC_DIR"/*.yml; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = bg-traefik.yml ] || [ -f "$REPO_DIR/traefik/dynamic/$(basename "$f")" ] || rm -f "$f"
  done
  if [ -e "$DYNAMIC_DIR/bg-traefik.yml" ]; then
    warn "BREAK-GLASS IS ENABLED: the Traefik dashboard accepts the Basic-auth login. Disable it: sudo scripts/breakglass.sh off"
  fi
  dc() { docker compose -p home-lab -f "$COMPOSE_FILE" --env-file "$LAB_ENV" --env-file "$APPS_ROOT/secrets/runtime.env" "$@"; }
  # Locally built images (ra-helper) are built first: Compose v5 only skips a buildable image on pull once it exists
  # locally, so on a fresh Pi `pull --ignore-buildable` alone tries to download home-lab/ra-helper and fails. The build is
  # cached when the Dockerfile is unchanged. A build needs the network, so --offline uses the existing images.
  up_args=(-d)
  if [ "$OFFLINE" -eq 0 ]; then
    dc build
    dc pull --ignore-buildable
    up_args+=(--build)
  fi
  [ -n "$ONLY" ] || up_args+=(--remove-orphans)
  [ "$RECREATE" -eq 0 ] || up_args+=(--force-recreate)
  dc up "${up_args[@]}"
  echo
  dc ps --format 'table {{.Name}}\t{{.Status}}'
fi

echo "== 4/4 certificate expiry"
cert_rc=0
"$SCRIPT_DIR/cert-expiry.sh" || cert_rc=$?
case "$cert_rc" in
  0) ;;
  1) warn "a Pi certificate expires within 30 days: reissue it now (docs/runbooks/m2-pi-setup.md, Renewal)" ;;
  *) warn "a Pi certificate is missing, unreadable or EXPIRED: secret fetch and ACME renewal stop working (docs/runbooks/m2-pi-setup.md, Renewal)" ;;
esac
# QA-M-3: units are not installed by deploy.sh (it changes nothing under /etc, on purpose: a deploy only runs what is already trusted).
# Say so loudly when a released unit is not installed yet; preflight fails on the same condition.
drift="$(unit_drift "$REPO_DIR" "$APPS_ROOT" || true)"
if [ -n "$drift" ]; then
  warn "systemd units are stale or missing: $(printf '%s' "$drift" | paste -sd";" -). Install them: sudo scripts/bootstrap.sh"
fi
echo "deploy finished"
