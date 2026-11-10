#!/usr/bin/env bash
# authentik-restore-laptop.sh - OWNER LAPTOP (K5, ADR-015): the two laptop steps of docs/runbooks/authentik-backup.md that need the
# age identity, as one command each, so the identity is never typed or pasted into a terminal.
#
# Usage:
#   scripts/authentik-restore-laptop.sh test  --bucket B [--profile P] [--version-id V | --dump-file F] [--key-from-stdin] [--keep]
#   scripts/authentik-restore-laptop.sh stage --bucket B [--profile P] [--version-id V] --pi-recipient age1... [--key-from-stdin]
#
#   test   section 5: pick a dump by the section 4 rules, download it by version, restore it into a throwaway PostgreSQL with no
#          network (the image and digest of authentik/compose.yaml), show what is inside, print RESULT: PASS or FAIL, clean up.
#   stage  section 6 step 2: pick and download the same way, re-encrypt it to the Pi's one-off key, upload it under restore/
#          and print a presigned URL valid for 900 seconds.
#   --version-id    use this version instead of the newest one that passes the rules (after a theft: one from before the incident)
#   --dump-file     test only: a local .dump.age instead of S3 (offline drills, self-tests)
#   --key-from-stdin  read the identity from standard input (a password manager CLI pipe) instead of the clipboard
#   --keep          test only: leave the throwaway container running for more queries (remove it with: docker rm -f <name>)
#
# The identity: by default the script stops and asks you to copy it from the password manager, then reads the clipboard once, keeps
# the key in memory only, and clears the clipboard. Why: a native age.exe in Git Bash never sees Ctrl-D or Ctrl-Z as end of input, so
# the old "paste the identity, press Ctrl-D" step hung (drill of 2026-11-10). The key is never printed, logged or written to disk.
set -uo pipefail

MODE="${1:-}"
[ $# -gt 0 ] && shift
BUCKET=""
PROFILE="${AWS_PROFILE:-}"
VERSION_ID=""
DUMP_FILE=""
PI_RECIPIENT=""
KEY_FROM_STDIN=0
KEEP=0
usage() { sed -n '2,23p' "$0"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

case "$MODE" in
  test | stage) ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket | --profile | --version-id | --dump-file | --pi-recipient)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
      case "$1" in
        --bucket) BUCKET="$2" ;;
        --profile) PROFILE="$2" ;;
        --version-id) VERSION_ID="$2" ;;
        --dump-file) DUMP_FILE="$2" ;;
        --pi-recipient) PI_RECIPIENT="$2" ;;
      esac
      shift 2
      ;;
    --key-from-stdin)
      KEY_FROM_STDIN=1
      shift
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# ------------------------------------------------------------------------------------------------ checks before anything happens
if ! command -v age > /dev/null 2>&1; then # winget installs age here and only new terminals get it on PATH
  for d in /c/Users/"${USERNAME:-x}"/AppData/Local/Microsoft/WinGet/Packages/FiloSottile.age*/age; do [ -d "$d" ] && PATH="$PATH:$d"; done
fi
command -v age > /dev/null 2>&1 || die "age is not installed (winget install --id FiloSottile.age --exact, or your package manager)"
if [ -n "$DUMP_FILE" ]; then
  [ "$MODE" = test ] || die "--dump-file is for test only; stage always uses S3"
  [ -s "$DUMP_FILE" ] || die "--dump-file $DUMP_FILE is missing or empty"
  [ -z "$VERSION_ID" ] || die "use --dump-file or --version-id, not both"
else
  [ -n "$BUCKET" ] || die "--bucket is required (terraform -chdir=terraform/bootstrap output -raw backup_bucket_name)"
  command -v aws > /dev/null 2>&1 || die "the aws CLI is not installed"
fi
if [ "$MODE" = stage ]; then
  [[ "$PI_RECIPIENT" =~ ^age1[02-9ac-hj-np-z]{58}$ ]] || die "--pi-recipient must be the Pi's one-off PUBLIC key (age1...), from age-keygen on the Pi"
  printf 'x' | age -r "$PI_RECIPIENT" > /dev/null 2>&1 || die "age does not accept --pi-recipient (a typo: copy the Public key line again)"
fi
if [ "$MODE" = test ]; then
  command -v docker > /dev/null 2>&1 || die "docker is not installed"
  docker info > /dev/null 2>&1 || die "Docker is not running: start Docker Desktop and run this again"
fi
AWS=(aws)
[ -n "$PROFILE" ] && AWS+=(--profile "$PROFILE")
if [ -z "$DUMP_FILE" ]; then
  "${AWS[@]}" sts get-caller-identity > /dev/null 2>&1 || die "AWS credentials do not work: aws sso login${PROFILE:+ --profile $PROFILE}"
fi

WORK="$(mktemp -d)"
chmod 0700 "$WORK"
CONTAINER="ak-restore-test-$$"
KEY=""
# shellcheck disable=SC2317,SC2329 # run by the EXIT trap
cleanup() {
  KEY=""
  rm -rf "$WORK"
  if [ "$MODE" = test ] && [ "$KEEP" -eq 0 ]; then docker rm -f "$CONTAINER" > /dev/null 2>&1 || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------------------------------------------ 1. choose the dump (section 4)
epoch() { date -u -d "$1" +%s 2> /dev/null; }
DUMP="$WORK/authentik.dump.age"
if [ -n "$DUMP_FILE" ]; then
  cp "$DUMP_FILE" "$DUMP"
  echo "1. dump: local file $DUMP_FILE ($(wc -c < "$DUMP") bytes)"
else
  echo "1. choosing a dump from s3://$BUCKET/authentik/ by S3's own metadata (never by name)"
  # shellcheck disable=SC2016 # the backticks are a JMESPath literal, not a shell expansion
  "${AWS[@]}" s3api list-object-versions --bucket "$BUCKET" --prefix authentik/ --output text \
    --query 'Versions[?ends_with(Key, `.dump.age`)].[LastModified,Key,VersionId,Size]' > "$WORK/versions.txt" || die "cannot list the bucket"
  sed -i '/^None$/d' "$WORK/versions.txt"
  sort -o "$WORK/versions.txt" "$WORK/versions.txt"
  [ -s "$WORK/versions.txt" ] || die "no dumps under authentik/ yet"
  now=$(date -u +%s)
  : > "$WORK/ok.txt"
  # shellcheck disable=SC2094 # versions.txt is only read here (by the loop and by awk); the loop writes ok.txt
  while IFS=$'\t' read -r lm key vid size; do
    why=""
    [ "$(awk -F'\t' -v k="$key" '$2 == k' "$WORK/versions.txt" | wc -l)" -eq 1 ] || why="more than one version of this key (an overwrite)"
    lm_s=$(epoch "$lm")
    ts=$(sed -nE 's#^authentik/([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z\.dump\.age$#\1-\2-\3 \4:\5:\6Z#p' <<< "$key")
    key_s=$(epoch "$ts")
    if [ -z "$why" ] && { [ -z "$lm_s" ] || [ -z "$key_s" ]; }; then why="name or LastModified cannot be read"; fi
    if [ -z "$why" ] && [ $((key_s > now + 300)) -eq 1 ]; then why="its name is in the future"; fi
    if [ -z "$why" ] && [ $(((lm_s - key_s) > 3600 || (key_s - lm_s) > 300)) -eq 1 ]; then why="its name and LastModified differ by more than an hour"; fi
    if [ -n "$why" ]; then echo "   REJECTED $key ($vid): $why"; else printf '%s\t%s\t%s\t%s\n' "$lm" "$key" "$vid" "$size" >> "$WORK/ok.txt"; fi
  done < "$WORK/versions.txt"
  if [ -n "$VERSION_ID" ]; then
    pick=$(awk -F'\t' -v v="$VERSION_ID" '$3 == v' "$WORK/ok.txt")
    [ -n "$pick" ] || die "version $VERSION_ID is not a dump that passes the rules (see REJECTED above, or a typo)"
  else
    pick=$(tail -n 1 "$WORK/ok.txt")
    [ -n "$pick" ] || die "no dump passes the rules"
  fi
  IFS=$'\t' read -r P_LM P_KEY P_VID P_SIZE <<< "$pick"
  median=$(awk -F'\t' -v v="$P_VID" '$3 != v {print $4}' "$WORK/ok.txt" | sort -n | awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]}')
  echo "   $(wc -l < "$WORK/ok.txt") dumps pass the rules; chosen: $P_KEY"
  echo "   LastModified $P_LM, $P_SIZE bytes, version $P_VID"
  if [ -n "$median" ] && [ "$median" -gt 0 ] && { [ $((P_SIZE * 2 < median)) -eq 1 ] || [ $((P_SIZE > median * 2)) -eq 1 ]; }; then
    echo "   WARN: its size is far from the others (median $median bytes): look at it before you trust it (section 4 rule 4)"
  fi
  "${AWS[@]}" s3api get-object --bucket "$BUCKET" --key "$P_KEY" --version-id "$P_VID" "$DUMP" > /dev/null || die "download failed"
fi
[ "$(head -c 21 "$DUMP")" = "age-encryption.org/v1" ] || die "the file is not age-encrypted: do not use it"

# ------------------------------------------------------------------------------------------------ 2. the identity
clip_read() {
  if [ -e /dev/clipboard ]; then cat /dev/clipboard
  elif command -v pbpaste > /dev/null 2>&1; then pbpaste
  elif command -v wl-paste > /dev/null 2>&1; then wl-paste -n
  elif command -v xclip > /dev/null 2>&1; then xclip -o -selection clipboard
  else return 1; fi
}
clip_clear() {
  if [ -e /dev/clipboard ]; then printf '' > /dev/clipboard
  elif command -v pbcopy > /dev/null 2>&1; then pbcopy < /dev/null
  elif command -v wl-copy > /dev/null 2>&1; then wl-copy --clear
  elif command -v xclip > /dev/null 2>&1; then xclip -selection clipboard < /dev/null; fi
}
if [ "$KEY_FROM_STDIN" -eq 1 ]; then
  KEY=$(tr -d '\r' | grep -oE 'AGE-SECRET-KEY-1[0-9A-Z]+')
else
  echo
  echo ">>> Now copy the age identity from the password manager (the note \"home-lab Authentik backup age identity\")."
  printf '>>> Then come back here and press Enter. '
  read -r _ < /dev/tty
  KEY=$(clip_read | tr -d '\r' | grep -oE 'AGE-SECRET-KEY-1[0-9A-Z]+') || true
  clip_clear
  echo "    clipboard read once and cleared"
fi
[ -n "$KEY" ] || die "no AGE-SECRET-KEY-1... found (copy the note again; with --key-from-stdin, pipe the note in)"
age_id() { printf '%s\n' "$KEY"; } # printf is a shell builtin: the key never appears in a process list

# Prove the key opens THIS dump before anything else: decrypt only its first bytes (a pg_dump custom file starts with PGDMP).
magic=$(age_id | age -d -i - "$DUMP" 2> /dev/null | head -c 5)
if [ "$magic" != "PGDMP" ]; then
  echo "2. key check: FAIL. This identity does not open the dump (wrong note, or the Pi encrypts to another public key)."
  echo "   The Pi's key is BACKUP_AGE_RECIPIENT in /etc/home-lab/aws.env; the note's '# public key:' line must be the same."
  echo "RESULT: FAIL"
  exit 1
fi
echo "2. key check: the identity opens this dump"

# ------------------------------------------------------------------------------------------------ 3a. stage for the Pi (section 6)
if [ "$MODE" = stage ]; then
  region=$("${AWS[@]}" s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text)
  [ -n "$region" ] && [ "$region" != None ] || region=us-east-1
  echo "3. re-encrypting to the Pi's one-off key and uploading to s3://$BUCKET/restore/ (plaintext only in the pipe)"
  age_id | age -d -i - "$DUMP" | age -r "$PI_RECIPIENT" | "${AWS[@]}" s3 cp - "s3://$BUCKET/restore/authentik-restore.dump.age" --only-show-errors
  codes=("${PIPESTATUS[@]}")
  if [ "${codes[1]}" != 0 ] || [ "${codes[2]}" != 0 ] || [ "${codes[3]}" != 0 ]; then
    echo "   decrypt ${codes[1]}, re-encrypt ${codes[2]}, upload ${codes[3]}"
    echo "RESULT: FAIL"
    exit 1
  fi
  url=$("${AWS[@]}" s3 presign "s3://$BUCKET/restore/authentik-restore.dump.age" --expires-in 900 --region "$region")
  echo "4. presigned URL (valid 900 seconds, ${#url} characters$([ "${#url}" -gt 4000 ] && echo ': TOO LONG for a paste, run again after a fresh aws sso login')):"
  echo
  echo "$url"
  echo
  echo "RESULT: PASS. Paste the URL at the Pi's hidden prompt (section 6 step 3). Afterwards remove it: section 6 step 4."
  exit 0
fi

# ------------------------------------------------------------------------------------------------ 3b. restore test (section 5)
image=$(sed -nE 's/^[[:space:]]+image:[[:space:]]*(postgres[^[:space:]]*@sha256:[0-9a-f]{64}).*/\1/p' "$(dirname "$0")/../authentik/compose.yaml" | head -n 1)
[ -n "$image" ] || die "cannot find the pinned postgres image in authentik/compose.yaml"
echo "3. starting a throwaway PostgreSQL with no network: $CONTAINER (${image%%@*})"
docker run -d --rm --name "$CONTAINER" --network none -e POSTGRES_DB=authentik -e POSTGRES_USER=authentik \
  -e POSTGRES_PASSWORD=throwaway-not-a-secret "$image" > /dev/null || die "docker run failed"
for _ in $(seq 1 60); do
  docker exec "$CONTAINER" pg_isready -U authentik -d authentik > /dev/null 2>&1 && break
  sleep 2
done
docker exec "$CONTAINER" pg_isready -U authentik -d authentik > /dev/null 2>&1 || die "the throwaway database did not start"

echo "4. decrypting and restoring (plaintext only in the pipe)"
age_id | age -d -i - "$DUMP" | docker exec -i "$CONTAINER" pg_restore -U authentik -d authentik --clean --if-exists --no-owner --exit-on-error
codes=("${PIPESTATUS[@]}")
KEY=""
q() { docker exec "$CONTAINER" psql -U authentik -d authentik -Atc "$1" 2> /dev/null; }
tables=$(q "select count(*) from pg_tables where schemaname = 'public'")
users=$(q "select count(*) from authentik_core_user")
echo "   age exit ${codes[1]}, pg_restore exit ${codes[2]}"
echo
echo "5. what is inside (compare with the live Pi, read-only:"
echo "   sudo docker exec authentik-postgresql sh -c 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -Atc \"select count(*) from authentik_core_user\"')"
echo "   tables:        ${tables:-0}"
echo "   users:         ${users:-0}"
q "select '     - ' || username || '  (' || type || ', ' || case when is_active then 'active' else 'inactive' end || ', last login ' || coalesce(last_login::date::text, 'never') || ')' from authentik_core_user order by date_joined"
echo "   applications:  $(q "select count(*) from authentik_core_application")"
echo "   authenticator tables: $(q "select count(*) from pg_class where relkind = 'r' and relname like 'authentik_stages_authenticator%'"), TOTP devices: $(q "select count(*) from authentik_stages_authenticator_totp_totpdevice"), WebAuthn devices: $(q "select count(*) from authentik_stages_authenticator_webauthn_webauthndevice")"
echo
if [ "${codes[1]}" = 0 ] && [ "${codes[2]}" = 0 ] && [ "${tables:-0}" -gt 0 ] && [ "${users:-0}" -gt 0 ]; then
  echo "RESULT: PASS, if the users above are all yours and the counts match the live Pi (an unknown account is a FAIL)."
  echo "Drill log line (pi-recovery.md): $(date -u +%F) | ${P_KEY:-$DUMP_FILE} ${P_VID:+version $P_VID} | users ${users} | tables ${tables} | PASS"
  [ "$KEEP" -eq 1 ] && echo "The container $CONTAINER is still running (--keep): docker rm -f $CONTAINER when done."
  exit 0
fi
echo "RESULT: FAIL. Do not restore this dump to the live database."
exit 1
