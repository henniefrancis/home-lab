#!/usr/bin/env bash
# set-secret.sh - owner-run, laptop-only: set the value of an SSM SecureString parameter under /home-lab/.
#
# Usage:
#   scripts/set-secret.sh <name>            prompt for a value and store it, e.g. authentik/secret-key
#   scripts/set-secret.sh --unset <name>    put the UNSET placeholder back (e.g. after Tailscale has joined)
#   scripts/set-secret.sh --create <name>   fallback mode only: create the SecureString (see docs/runbooks/secrets-ssm.md)
#
# Every write passes --key-id (default alias/home-lab-ssm, the customer-managed key from terraform/bootstrap), so a re-set
# also re-encrypts an old value under that key. The value is read with no echo, travels only through shell builtins and
# pipes, and is never placed in argv, shell history or a file in the repo. Limits: 1 to 4096 characters, a trailing CR (from
# a Windows terminal or clipboard) is removed. On Git Bash (where aws.exe cannot read /dev/stdin) the request body goes
# through a private temp file in a directory only the current user can access; the file is overwritten with random data
# and removed on every exit path. WSL or Linux avoids the file entirely and is preferred for secrets. Never paste values
# into chats or agents.
#
# Environment: AWS_PROFILE_NAME (default henniefrancis), AWS_SSM_REGION (default af-south-1), SSM_KEY_ALIAS (default
# alias/home-lab-ssm).
set -euo pipefail
umask 077
# Git Bash on Windows would rewrite /home-lab/... into a Windows path.
export MSYS_NO_PATHCONV=1

PROFILE="${AWS_PROFILE_NAME:-henniefrancis}"
REGION="${AWS_SSM_REGION:-af-south-1}"
KEY_ID="${SSM_KEY_ALIAS:-alias/home-lab-ssm}"
PLACEHOLDER="UNSET-set-via-set-secret"
MAX_LEN=4096
MODE="set"

usage() { sed -n '2,17p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --unset)
      MODE="unset"
      shift
      ;;
    --create)
      MODE="create"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || {
  usage >&2
  exit 2
}
NAME="$1"

# Only secret parameters of the form <service>/<name>; config/* is owned by Terraform.
if ! [[ "$NAME" =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || [[ "$NAME" == config/* ]]; then
  echo "Refusing '$NAME': expected <service>/<name> (lowercase letters, digits, hyphen), never config/*." >&2
  exit 2
fi
[[ "$KEY_ID" =~ ^alias/[A-Za-z0-9/_-]{1,250}$ ]] || {
  echo "SSM_KEY_ALIAS must look like alias/<name>." >&2
  exit 2
}
PARAM="/home-lab/$NAME"

aws_() { aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@"; }

TMPDIR_PRIV=""
v=""
v2=""
cleanup() {
  local rc=$?
  if [ -n "$TMPDIR_PRIV" ] && [ -d "$TMPDIR_PRIV" ]; then
    # Best effort overwrite before unlinking (NTFS keeps no secure-delete guarantee; see the header).
    for f in "$TMPDIR_PRIV"/*; do
      [ -f "$f" ] || continue
      size="$(wc -c < "$f" | tr -d ' ')"
      head -c "${size:-0}" /dev/urandom > "$f" 2> /dev/null || true
    done
    rm -rf "$TMPDIR_PRIV"
  fi
  unset v v2
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! aws_ sts get-caller-identity --query Account --output text > /dev/null 2>&1; then
  echo "Not authenticated. Run: aws sso login --profile $PROFILE" >&2
  exit 1
fi

if [ "$MODE" != create ]; then
  # Type only: no --with-decryption and no Value in the output.
  ptype="$(aws_ ssm get-parameter --name "$PARAM" --query Parameter.Type --output text 2> /dev/null || true)"
  if [ "$ptype" != SecureString ]; then
    echo "$PARAM does not exist as a SecureString (apply terraform/edge first, or use --create in fallback mode)." >&2
    exit 1
  fi
fi

case "$MODE" in
  unset)
    v="$PLACEHOLDER"
    ;;
  *)
    printf 'Value for %s (no echo): ' "$PARAM" >&2
    if ! IFS= read -rs v; then
      printf '\n' >&2
      echo "No input (end of file); nothing written." >&2
      exit 1
    fi
    printf '\nRepeat: ' >&2
    if ! IFS= read -rs v2; then
      printf '\n' >&2
      echo "No input (end of file); nothing written." >&2
      exit 1
    fi
    printf '\n' >&2
    # A Windows terminal or clipboard can leave a carriage return behind; it is never part of a secret here.
    v="${v%$'\r'}"
    v2="${v2%$'\r'}"
    if [ -z "$v" ]; then
      echo "Refusing an empty value." >&2
      exit 1
    fi
    if [ "${#v}" -gt "$MAX_LEN" ]; then
      echo "Refusing a value of ${#v} characters: SSM standard parameters take at most $MAX_LEN." >&2
      exit 1
    fi
    if [ "$v" != "$v2" ]; then
      echo "Values differ; nothing written." >&2
      exit 1
    fi
    if [[ "$v" == UNSET-* ]]; then
      echo "Refusing a value that looks like the placeholder (use --unset)." >&2
      exit 1
    fi
    ;;
esac

overwrite=true
[ "$MODE" = create ] && overwrite=false

# Build the request body from stdin (value never in argv); only the parameter name and key alias go to jq as arguments.
build_body() {
  printf '%s' "$v" | jq -Rs --arg n "$PARAM" --arg k "$KEY_ID" --argjson o "$overwrite" \
    '{Name:$n, Value:., Type:"SecureString", KeyId:$k, Tier:"Standard", Overwrite:$o}'
}

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    TMPDIR_PRIV="$(mktemp -d)"
    chmod 700 "$TMPDIR_PRIV"
    # chmod is a no-op on NTFS: restrict the directory to the current user with an ACL instead.
    win_dir="$(cygpath -w "$TMPDIR_PRIV")"
    if command -v icacls > /dev/null 2>&1 && [ -n "${USERNAME:-}" ]; then
      icacls "$win_dir" /inheritance:r /grant:r "${USERNAME}:(OI)(CI)F" > /dev/null 2>&1 ||
        echo "WARN: could not restrict the temp directory ACL; prefer WSL for secrets." >&2
    fi
    build_body > "$TMPDIR_PRIV/req.json"
    win_path="$(cygpath -m "$TMPDIR_PRIV/req.json")"
    out="$(aws_ ssm put-parameter --cli-input-json "file://$win_path" --query Version --output text)"
    ;;
  *)
    out="$(build_body | aws_ ssm put-parameter --cli-input-json file:///dev/stdin --query Version --output text)"
    ;;
esac

echo "Stored $PARAM (version $out, key $KEY_ID)."
