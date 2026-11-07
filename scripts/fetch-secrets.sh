#!/usr/bin/env bash
# fetch-secrets.sh - Pi, root: fetch the lab's secrets and config from SSM Parameter Store into /apps/secrets.
#
# Usage: sudo scripts/fetch-secrets.sh [--dry-run] [--manifest FILE] [--apps-root DIR] [--etc-dir DIR]
#   --dry-run   do everything except publish (checks AWS access, placeholders, manifest); changes nothing on disk after exit.
#
# How it works (plan 3.3 and 6.10):
#   - Identity: AWS CLI v2 with a credential_process profile that runs aws_signing_helper with the pi-host cert/key
#     (IAM Roles Anywhere role home-lab-pi-host). ARNs come from /etc/home-lab/aws.env. No long-lived keys.
#   - One call: ssm get-parameters-by-path /home-lab --recursive --with-decryption. The JSON lives only in a tmpfs
#     directory (/run) and is shredded on exit. Values go straight from jq into files: never argv, never echoed.
#   - config/secrets-manifest.tsv maps parameters to files (owner, mode, required, format).
#   - A release dir is built under $APPS_ROOT/.secrets.d/.staging-*, validated, then published by atomically re-pointing
#     the symlink $APPS_ROOT/secrets at it (rename(2) over the old symlink). The last two releases are kept.
#   - Fails closed: a required parameter that is missing or still UNSET-* aborts; nothing is published and the previous
#     secrets stay in place. The staging dir is removed on every exit path, including Ctrl-C and SIGTERM.
#   - Writes $APPS_ROOT/secrets/runtime.env (DOMAIN, ROUTE53_ZONE_ID, RA_* ARNs) from the manifest's env: rows.
# Exit codes: 0 ok, 2 usage, 3 AWS unreachable or denied (existing secrets untouched), 4 validation failed
#             (placeholder or missing required parameter, wrong type, bad manifest), 1 other error.
# After a secret changes, recreate the consuming service: files are replaced, not edited in place, so a running
# container keeps the old bind-mounted file until it is recreated (docker compose up -d --force-recreate <service>).
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
LAB_ENV="$REPO_DIR/config/lab.env"
MANIFEST="$REPO_DIR/config/secrets-manifest.tsv"
APPS_ROOT="$(lab_env_get "$LAB_ENV" APPS_ROOT /apps)"
REGION="$(lab_env_get "$LAB_ENV" AWS_SSM_REGION af-south-1)"
ETC_DIR=/etc/home-lab
PLACEHOLDER_PREFIX="UNSET-"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --manifest)
      MANIFEST="${2:?}"
      shift 2
      ;;
    --apps-root)
      APPS_ROOT="${2:?}"
      shift 2
      ;;
    --etc-dir)
      ETC_DIR="${2:?}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
require_root "$@"
command -v jq > /dev/null || die "jq not installed (run bootstrap.sh)"
command -v aws > /dev/null || die "aws CLI not installed (run bootstrap.sh)"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

SECRETS_LINK="$APPS_ROOT/secrets"
RELEASES="$APPS_ROOT/.secrets.d"
RAMDIR=""
STAGE=""
NEWLINK="$APPS_ROOT/.secrets.new"

cleanup() {
  local rc=$?
  [ -z "$RAMDIR" ] || rm -rf "$RAMDIR"
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  rm -f "$NEWLINK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail_validation() {
  echo "ERROR: $*" >&2
  exit 4
}

# ------------------------------------------------------------ manifest
declare -a M_PARAM M_TARGET M_OWNER M_MODE M_REQ M_FMT
declare -A TARGET_META=()
while IFS=$'\t' read -r param target owner mode req fmt extra; do
  case "$param" in '' | '#'*) continue ;; esac
  [ -z "${extra:-}" ] || fail_validation "manifest row for '$param' has more than 6 columns"
  [[ "$param" =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || fail_validation "manifest: bad parameter name '$param'"
  [[ "$target" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || fail_validation "manifest: bad target path for '$param'"
  case "/$target/" in */../*) fail_validation "manifest: '..' in target for '$param'" ;; esac
  [[ "$owner" =~ ^[0-9]+:[0-9]+$ ]] || fail_validation "manifest: owner of '$param' must be numeric uid:gid"
  [[ "$mode" =~ ^0[0-7]{3}$ ]] || fail_validation "manifest: mode of '$param' must look like 0400"
  case "$req" in yes | no | empty) ;; *) fail_validation "manifest: required of '$param' must be yes, no or empty" ;; esac
  case "$fmt" in
    raw) ;;
    env:[A-Z][A-Z0-9_]*) ;;
    *) fail_validation "manifest: format of '$param' must be raw or env:NAME" ;;
  esac
  meta="$owner $mode"
  if [ -n "${TARGET_META[$target]:-}" ]; then
    [ "${TARGET_META[$target]}" = "$meta" ] || fail_validation "manifest: rows sharing '$target' disagree on owner or mode"
    [[ "$fmt" == env:* ]] || fail_validation "manifest: only env: rows may share a target ('$target')"
  fi
  TARGET_META[$target]="$meta"
  M_PARAM+=("$param")
  M_TARGET+=("$target")
  M_OWNER+=("$owner")
  M_MODE+=("$mode")
  M_REQ+=("$req")
  M_FMT+=("$fmt")
done < "$MANIFEST"
[ "${#M_PARAM[@]}" -gt 0 ] || fail_validation "manifest has no rows"

# ------------------------------------------------------------ AWS identity
AWS_ENV="$ETC_DIR/aws.env"
[ -f "$AWS_ENV" ] || die "$AWS_ENV missing (runbook step: write it from terraform output, U13)"
[ "$(stat -c '%a %u' "$AWS_ENV")" = "600 0" ] || die "$AWS_ENV must be root-owned with mode 0600"
TA_ARN="$(lab_env_get "$AWS_ENV" RA_TRUST_ANCHOR_ARN)"
PROFILE_ARN="$(lab_env_get "$AWS_ENV" RA_HOST_PROFILE_ARN)"
ROLE_ARN="$(lab_env_get "$AWS_ENV" RA_HOST_ROLE_ARN)"
AWS_REGION_CFG="$(lab_env_get "$AWS_ENV" AWS_REGION "$REGION")"
[[ "$TA_ARN" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:trust-anchor/[0-9a-f-]+$ ]] || die "RA_TRUST_ANCHOR_ARN in $AWS_ENV is missing or malformed"
[[ "$PROFILE_ARN" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:profile/[0-9a-f-]+$ ]] || die "RA_HOST_PROFILE_ARN in $AWS_ENV is missing or malformed"
[[ "$ROLE_ARN" =~ ^arn:aws[a-z-]*:iam::[0-9]+:role/[A-Za-z0-9+=,.@_/-]+$ ]] || die "RA_HOST_ROLE_ARN in $AWS_ENV is missing or malformed"
[[ "$AWS_REGION_CFG" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || die "AWS_REGION in $AWS_ENV is malformed"
[ -r "$ETC_DIR/pki/host.crt" ] && [ -r "$ETC_DIR/pki/host.key" ] || die "host certificate or key missing in $ETC_DIR/pki"

AWS_CONFIG_PATH="$ETC_DIR/aws-config"
cfg_tmp="$(mktemp "$AWS_CONFIG_PATH.XXXXXX")"
cat > "$cfg_tmp" << CFG
[profile home-lab-host]
region = $AWS_REGION_CFG
credential_process = /usr/local/bin/aws_signing_helper credential-process --certificate $ETC_DIR/pki/host.crt --private-key $ETC_DIR/pki/host.key --trust-anchor-arn $TA_ARN --profile-arn $PROFILE_ARN --role-arn $ROLE_ARN --session-duration 3600
CFG
chmod 0600 "$cfg_tmp"
mv -f "$cfg_tmp" "$AWS_CONFIG_PATH"

# ------------------------------------------------------------ working dirs
install -d -m 0700 -o root -g root "$APPS_ROOT" "$RELEASES"
if [ -d /run ] && [ -w /run ]; then
  RAMDIR="$(mktemp -d /run/home-lab-fetch.XXXXXX)"
else
  RAMDIR="$(mktemp -d)"
fi
STAGE="$(mktemp -d "$RELEASES/.staging-XXXXXX")"
chmod 0700 "$STAGE"

# ------------------------------------------------------------ fetch (the only network call)
aws_clean_env() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE -u AWS_DEFAULT_PROFILE \
    AWS_CONFIG_FILE="$AWS_CONFIG_PATH" AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=home-lab-host \
    AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" "$@"
}
if ! aws_clean_env aws ssm get-parameters-by-path --path /home-lab --recursive --with-decryption \
  --output json --region "$AWS_REGION_CFG" --no-cli-pager > "$RAMDIR/params.json" 2> "$RAMDIR/aws.err"; then
  echo "ERROR: could not fetch parameters from SSM (offline, certificate rejected, or access denied)." >&2
  echo "       Existing secrets are untouched. AWS said:" >&2
  head -c 600 "$RAMDIR/aws.err" | sed 's/^/       /' >&2
  exit 3
fi
jq -e '.Parameters | type == "array"' "$RAMDIR/params.json" > /dev/null 2>&1 || {
  echo "ERROR: unexpected SSM response shape." >&2
  exit 3
}
P="$RAMDIR/params.json"

# ------------------------------------------------------------ build the release
errors=0
declare -A SEEN_TARGET=()
written=0
omitted=0
for i in "${!M_PARAM[@]}"; do
  param="${M_PARAM[$i]}"
  full="/home-lab/$param"
  target="${M_TARGET[$i]}"
  req="${M_REQ[$i]}"
  fmt="${M_FMT[$i]}"
  dest="$STAGE/$target"

  count="$(jq -r --arg n "$full" '[.Parameters[] | select(.Name == $n)] | length' "$P")"
  placeholder=0
  if [ "$count" -eq 0 ]; then
    if [ "$req" = yes ]; then
      echo "FAIL  $param: parameter not found in SSM" >&2
      errors=$((errors + 1))
      continue
    fi
    placeholder=1
  else
    want_type=SecureString
    [[ "$param" == config/* ]] && want_type=String
    have_type="$(jq -r --arg n "$full" '.Parameters[] | select(.Name == $n) | .Type' "$P")"
    if [ "$have_type" != "$want_type" ]; then
      echo "FAIL  $param: type is $have_type, expected $want_type" >&2
      errors=$((errors + 1))
      continue
    fi
    if jq -e --arg n "$full" --arg p "$PLACEHOLDER_PREFIX" '.Parameters[] | select(.Name == $n) | .Value | startswith($p)' "$P" > /dev/null; then
      placeholder=1
    fi
  fi

  if [ "$placeholder" -eq 1 ]; then
    case "$req" in
      yes)
        echo "FAIL  $param: still holds the UNSET placeholder (set it with scripts/set-secret.sh)" >&2
        errors=$((errors + 1))
        continue
        ;;
      no)
        echo "skip  $param: placeholder, file omitted (optional)"
        omitted=$((omitted + 1))
        continue
        ;;
      empty)
        install -d -m 0700 -o root -g root "$(dirname "$dest")"
        : > "$dest"
        SEEN_TARGET[$target]=1
        echo "empty $param: placeholder, empty file written"
        written=$((written + 1))
        continue
        ;;
    esac
  fi

  install -d -m 0700 -o root -g root "$(dirname "$dest")"
  if [ "$fmt" = raw ]; then
    jq -j --arg n "$full" '.Parameters[] | select(.Name == $n) | .Value' "$P" > "$dest"
  else
    var="${fmt#env:}"
    if ! jq -e --arg n "$full" '.Parameters[] | select(.Name == $n) | .Value | test("^[A-Za-z0-9_./:@+=,-]+$")' "$P" > /dev/null; then
      echo "FAIL  $param: value has characters that are unsafe in an env file" >&2
      errors=$((errors + 1))
      continue
    fi
    jq -j --arg n "$full" --arg k "$var" '.Parameters[] | select(.Name == $n) | ($k + "=" + .Value + "\n")' "$P" >> "$dest"
  fi
  SEEN_TARGET[$target]=1
  echo "ok    $param -> $target"
  written=$((written + 1))
done

if [ "$errors" -gt 0 ]; then
  fail_validation "$errors parameter(s) failed validation; nothing was published, existing secrets are untouched"
fi

# Owners and modes for every file that was written; directories stay root 0700.
for i in "${!M_PARAM[@]}"; do
  target="${M_TARGET[$i]}"
  [ -n "${SEEN_TARGET[$target]:-}" ] || continue
  chown "${M_OWNER[$i]}" "$STAGE/$target"
  chmod "${M_MODE[$i]}" "$STAGE/$target"
done

# Names present in SSM but not in the manifest (names only).
while IFS= read -r name; do
  found=0
  for p in "${M_PARAM[@]}"; do [ "/home-lab/$p" = "$name" ] && found=1 && break; done
  [ "$found" -eq 1 ] || echo "note  $name is in SSM but not in the manifest"
done < <(jq -r '.Parameters[].Name' "$P")

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run: $written file(s) would be written, $omitted omitted; nothing published."
  exit 0
fi

# ------------------------------------------------------------ publish atomically
release="release-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mv "$STAGE" "$RELEASES/$release"
STAGE=""
chmod 0700 "$RELEASES/$release"
if [ -d "$SECRETS_LINK" ] && [ ! -L "$SECRETS_LINK" ]; then
  # First run after bootstrap: a real (empty) directory sits where the symlink goes.
  if ! rmdir "$SECRETS_LINK" 2> /dev/null; then
    mv "$SECRETS_LINK" "$RELEASES/pre-symlink-$release"
    warn "moved the existing non-empty $SECRETS_LINK to $RELEASES/pre-symlink-$release"
  fi
fi
ln -s ".secrets.d/$release" "$NEWLINK"
mv -T "$NEWLINK" "$SECRETS_LINK"

# Keep the three newest releases (current plus two); never remove the one in use.
current="$(readlink "$SECRETS_LINK")"
# shellcheck disable=SC2012
ls -1d "$RELEASES"/release-* 2> /dev/null | sort | head -n -3 | while IFS= read -r old; do
  [ ".secrets.d/$(basename "$old")" = "$current" ] || rm -rf "$old"
done

echo "published: $written file(s) written, $omitted omitted -> $SECRETS_LINK ($release)"
