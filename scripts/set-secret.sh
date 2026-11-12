#!/usr/bin/env bash
# set-secret.sh - owner-run, laptop-only: set the value of an SSM SecureString parameter under /home-lab/.
#
# Usage:
#   scripts/set-secret.sh <name>            prompt for a value and store it, e.g. authentik/secret-key
#   scripts/set-secret.sh --unset <name>    put the UNSET placeholder back (e.g. after Tailscale has joined)
#   scripts/set-secret.sh --create <name>   create the SecureString (with the UNSET placeholder, key alias/home-lab-ssm, Standard tier,
#                                           tags Project=home-lab and ManagedBy=set-secret.sh); refuses if it already exists; then set it
#   scripts/set-secret.sh --generate <name>...  for MACHINE-ONLY secrets nobody needs to know (database passwords, signing keys): create each
#                                           SecureString with a random value (64 hex characters from openssl rand). Refuses a name that
#                                           already exists (it may hold a value something already uses) or is not in the manifest. The
#                                           value is never shown, logged or placed in argv. Human passwords: use <name> (the prompt).
#   scripts/set-secret.sh --check           list every expected SecureString with its key and version (never a value); exit 1 when one is
#                                           missing, is not a SecureString or is not on the home-lab key
#
# The SecureStrings are owner-managed, NOT Terraform-managed (ADR-013): config/secrets-manifest.tsv (rows that do not start with
# config/) is the source of truth for the list. Terraform owns only /home-lab/config/*.
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

usage() { sed -n '2,27p' "$0"; }

MANIFEST="${SECRETS_MANIFEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/secrets-manifest.tsv}"
expected_names() { grep -vE '^(#|$)' "$MANIFEST" | cut -f1 | tr -d '\r' | grep -v '^config/'; }
# NEW-10: read the list ONCE into a variable. A process substitution hid a failing expected_names (a missing manifest made --check
# print "check OK" with nothing checked), and `expected_names | grep -q` under pipefail could fail on SIGPIPE for a large manifest.
EXPECTED=""
load_expected() {
  EXPECTED="$(expected_names 2> /dev/null)" || EXPECTED=""
  [ -n "$EXPECTED" ] || {
    echo "Cannot read any SecureString row from $MANIFEST (missing, empty or comments only); refusing to continue." >&2
    exit 2
  }
}

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
    --check)
      MODE="check"
      shift
      ;;
    --generate)
      MODE="generate"
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
if [ "$MODE" = check ]; then
  [ $# -eq 0 ] || {
    usage >&2
    exit 2
  }
elif [ "$MODE" = generate ]; then
  [ $# -ge 1 ] || {
    usage >&2
    exit 2
  }
else
  [ $# -eq 1 ] || {
    usage >&2
    exit 2
  }
fi
NAME="${1:-}"
NAMES=("$@")
[ "$MODE" = generate ] || NAMES=("$NAME")

# Only secret parameters of the form <service>/<name>; config/* is owned by Terraform.
if [ "$MODE" != check ]; then
  for n in "${NAMES[@]}"; do
    if ! [[ "$n" =~ ^[a-z0-9-]+/[a-z0-9-]+$ ]] || [[ "$n" == config/* ]]; then
      echo "Refusing '$n': expected <service>/<name> (lowercase letters, digits, hyphen), never config/*." >&2
      exit 2
    fi
  done
fi
if [ "$MODE" = create ] || [ "$MODE" = generate ]; then
  load_expected
  for n in "${NAMES[@]}"; do
    if ! grep -qxF -- "$n" <<< "$EXPECTED"; then
      echo "Refusing to create '$n': it is not a SecureString row of config/secrets-manifest.tsv (add it there first)." >&2
      exit 2
    fi
  done
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

if [ "$MODE" = check ]; then
  # Metadata only (name, type, key, version): describe-parameters never returns a value.
  load_expected
  listing="$(aws_ ssm describe-parameters --parameter-filters "Key=Path,Option=Recursive,Values=/home-lab" \
    --query 'Parameters[].{n:Name,t:Type,k:KeyId,v:Version}' --output json)"
  jq -e 'type == "array"' <<< "$listing" > /dev/null 2>&1 || {
    echo "Unexpected describe-parameters output (not a JSON list); check FAILED." >&2
    exit 1
  }
  bad=0
  printf '%-40s %-22s %s\n' "parameter" "key" "version"
  while IFS= read -r want; do
    row="$(jq -r --arg n "/home-lab/$want" '[.[] | select(.n == $n)] | if length == 0 then "MISSING" else .[0] | "\(.t)|\(.k // "-")|\(.v)" end' <<< "$listing")"
    if [ "$row" = MISSING ]; then
      printf '%-40s %-22s %s\n' "$want" "-" "MISSING"
      bad=1
      continue
    fi
    rtype="${row%%|*}"
    rest="${row#*|}"
    rkey="${rest%%|*}"
    rver="${rest#*|}"
    flag=""
    if [ "$rtype" != SecureString ]; then flag=" (NOT a SecureString)"; bad=1; fi
    if [ "$rkey" != "$KEY_ID" ]; then flag="$flag (NOT on $KEY_ID)"; bad=1; fi
    printf '%-40s %-22s %s%s\n' "$want" "$rkey" "$rver" "$flag"
  done <<< "$EXPECTED"
  if [ "$bad" -ne 0 ]; then
    echo "check FAILED: fix with scripts/set-secret.sh --create <name> (missing) or by setting the value again (wrong key)." >&2
    exit 1
  fi
  echo "check OK: every expected SecureString exists and is on $KEY_ID."
  exit 0
fi

if [ "$MODE" != create ] && [ "$MODE" != generate ]; then
  # Type only: no --with-decryption and no Value in the output.
  ptype="$(aws_ ssm get-parameter --name "$PARAM" --query Parameter.Type --output text 2> /dev/null || true)"
  if [ "$ptype" != SecureString ]; then
    echo "$PARAM does not exist as a SecureString (create it first: scripts/set-secret.sh --create ${NAME})." >&2
    exit 1
  fi
fi

case "$MODE" in
  unset | create)
    v="$PLACEHOLDER"
    ;;
  generate)
    : # the values are created one by one below; nothing is read from the terminal
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
    # Portainer and Speedtest Tracker hash their admin password with bcrypt, which takes at most 72 bytes: a longer one stops Portainer from
    # starting ("failed hashing admin password", seen on the R17 deploy, 2026-11-11) and Laravel's hasher rejects it too (R19).
    if { [ "$NAME" = portainer/admin-password ] || [ "$NAME" = speedtest/admin-password ]; } && [ "$(printf '%s' "$v" | LC_ALL=C wc -c | tr -d ' ')" -gt 72 ]; then
      echo "Refusing a password of more than 72 bytes for $NAME (bcrypt limit); use 64 characters or fewer. Nothing written." >&2
      exit 1
    fi
    # The CouchDB sync password is typed by hand and the CouchDB host is reachable by every device on the LAN and the tailnet: at least 20 characters.
    if [ "$NAME" = couchdb/sync-password ] && [ "$(printf '%s' "$v" | LC_ALL=C wc -c | tr -d ' ')" -lt 20 ]; then
      echo "Refusing a CouchDB sync password of fewer than 20 characters (it guards the notes of every device). Nothing written." >&2
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
[ "$MODE" = generate ] && overwrite=false

# Build the request body from stdin (value never in argv); only the parameter name and key alias go to jq as arguments.
build_body() {
  # Tags are only accepted by PutParameter when Overwrite is false, i.e. on --create.
  printf '%s' "$v" | jq -Rs --arg n "$PARAM" --arg k "$KEY_ID" --argjson o "$overwrite" --arg m "$MODE" \
    '{Name:$n, Value:., Type:"SecureString", KeyId:$k, Tier:"Standard", Overwrite:$o}
     + (if $m == "create" then {Tags:[{Key:"Project",Value:"home-lab"},{Key:"ManagedBy",Value:"set-secret.sh"}]} else {} end)'
}

put_value() { # sends $v to $PARAM; sets $out to the new version
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      if [ -z "$TMPDIR_PRIV" ]; then
        TMPDIR_PRIV="$(mktemp -d)"
        chmod 700 "$TMPDIR_PRIV"
        # chmod is a no-op on NTFS: restrict the directory to the current user with an ACL instead.
        win_dir="$(cygpath -w "$TMPDIR_PRIV")"
        if command -v icacls > /dev/null 2>&1 && [ -n "${USERNAME:-}" ]; then
          icacls "$win_dir" /inheritance:r /grant:r "${USERNAME}:(OI)(CI)F" > /dev/null 2>&1 ||
            echo "WARN: could not restrict the temp directory ACL; prefer WSL for secrets." >&2
        fi
      fi
      build_body > "$TMPDIR_PRIV/req.json"
      win_path="$(cygpath -m "$TMPDIR_PRIV/req.json")"
      out="$(aws_ ssm put-parameter --cli-input-json "file://$win_path" --query Version --output text)"
      # Overwrite the request body (it held the value) before the next one; the EXIT trap removes the directory.
      size="$(wc -c < "$TMPDIR_PRIV/req.json" | tr -d ' ')"
      head -c "${size:-0}" /dev/urandom > "$TMPDIR_PRIV/req.json" 2> /dev/null || true
      ;;
    *)
      out="$(build_body | aws_ ssm put-parameter --cli-input-json file:///dev/stdin --query Version --output text)"
      ;;
  esac
}

if [ "$MODE" = generate ]; then
  rc_all=0
  for n in "${NAMES[@]}"; do
    PARAM="/home-lab/$n"
    # Existence only (type, no value): never overwrite something that may already be in use.
    if aws_ ssm get-parameter --name "$PARAM" --query Parameter.Type --output text > /dev/null 2>&1; then
      echo "Skipped $PARAM: it already exists (a value may be in use). To replace it on purpose: scripts/set-secret.sh $n" >&2
      rc_all=1
      continue
    fi
    v="$(openssl rand -hex 32 2> /dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    [[ "$v" =~ ^[0-9a-f]{64}$ ]] || {
      echo "Could not generate a random value for $PARAM; nothing written." >&2
      exit 1
    }
    MODE=create # build_body adds the Project and ManagedBy tags on a create
    put_value
    MODE=generate
    v=""
    echo "Generated $PARAM (version $out, key $KEY_ID, value never shown)."
  done
  exit "$rc_all"
fi

put_value
echo "Stored $PARAM (version $out, key $KEY_ID)."
