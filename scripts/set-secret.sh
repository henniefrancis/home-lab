#!/usr/bin/env bash
# set-secret.sh - owner-run, laptop-only: set the value of an SSM SecureString parameter under /home-lab/.
#
# Usage:
#   scripts/set-secret.sh <name>            prompt for a value and store it, e.g. authentik/secret-key
#   scripts/set-secret.sh --unset <name>    put the UNSET placeholder back (e.g. after Tailscale has joined)
#   scripts/set-secret.sh --create <name>   fallback mode only: create the SecureString (see docs/runbooks/secrets-ssm.md)
#
# The value is read with no echo, travels only through shell builtins and pipes, and is never placed in argv,
# shell history or a file in the repo. On Git Bash (where aws.exe cannot read /dev/stdin) the request body goes
# through a private temp file that is always removed, even on error. Never paste values into chats or agents.
#
# Environment: AWS_PROFILE_NAME (default henniefrancis), AWS_SSM_REGION (default af-south-1).
set -euo pipefail
umask 077
# Git Bash on Windows would rewrite /home-lab/... into a Windows path.
export MSYS_NO_PATHCONV=1

PROFILE="${AWS_PROFILE_NAME:-henniefrancis}"
REGION="${AWS_SSM_REGION:-af-south-1}"
PLACEHOLDER="UNSET-set-via-set-secret"
MODE="set"

usage() { sed -n '2,10p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --unset) MODE="unset"; shift ;;
    --create) MODE="create"; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { usage >&2; exit 2; }
NAME="$1"

# Only secret parameters of the form <service>/<name>; config/* is owned by Terraform.
if ! [[ "$NAME" =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || [[ "$NAME" == config/* ]]; then
  echo "Refusing '$NAME': expected <service>/<name> (lowercase letters, digits, hyphen), never config/*." >&2
  exit 2
fi
PARAM="/home-lab/$NAME"

aws_() { aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@"; }

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

TMPDIR_PRIV=""
cleanup() {
  [ -n "$TMPDIR_PRIV" ] && rm -rf "$TMPDIR_PRIV"
  unset v v2 2> /dev/null || true
}
trap cleanup EXIT INT TERM

case "$MODE" in
  unset)
    v="$PLACEHOLDER"
    ;;
  *)
    printf 'Value for %s (no echo): ' "$PARAM" >&2
    IFS= read -rs v
    printf '\nRepeat: ' >&2
    IFS= read -rs v2
    printf '\n' >&2
    if [ -z "$v" ]; then echo "Refusing an empty value." >&2; exit 1; fi
    if [ "$v" != "$v2" ]; then echo "Values differ; nothing written." >&2; exit 1; fi
    if [[ "$v" == UNSET-* ]]; then echo "Refusing a value that looks like the placeholder (use --unset)." >&2; exit 1; fi
    ;;
esac

overwrite=true
[ "$MODE" = create ] && overwrite=false

# Build the request body from stdin (value never in argv); only the parameter name is passed to jq as an argument.
build_body() {
  printf '%s' "$v" | jq -Rs --arg n "$PARAM" --argjson o "$overwrite" \
    '{Name:$n, Value:., Type:"SecureString", Tier:"Standard", Overwrite:$o}'
}

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    TMPDIR_PRIV="$(mktemp -d)"
    chmod 700 "$TMPDIR_PRIV"
    build_body > "$TMPDIR_PRIV/req.json"
    win_path="$(cygpath -m "$TMPDIR_PRIV/req.json")"
    out="$(aws_ ssm put-parameter --cli-input-json "file://$win_path" --query Version --output text)"
    ;;
  *)
    out="$(build_body | aws_ ssm put-parameter --cli-input-json file:///dev/stdin --query Version --output text)"
    ;;
esac

echo "Stored $PARAM (version $out)."
