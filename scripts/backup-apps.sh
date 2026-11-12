#!/usr/bin/env bash
# backup-apps.sh - Pi, root: encrypted off-Pi backups of the R17 apps' data (owner decision 2026-11-10), the same way as the Authentik
# backup (scripts/backup-authentik.sh, ADR-015) but for these jobs:
#
#   job               source                                                       object (under s3://<bucket>/apps/<job>/)
#   linkwarden-db     pg_dump -Fc inside linkwarden-postgresql (password file)    <UTC>.dump.age
#   linkwarden-data   tar of APPS_ROOT/linkwarden/data (saved pages, screenshots)   <UTC>.tar.age
#   homeassistant     tar of APPS_ROOT/homeassistant/config, without the history   <UTC>.tar.age
#                     database (home-assistant_v2.db*: big, rebuilt, and unsafe to copy while it is written)
#   pihole            tar of APPS_ROOT/pihole/etc-pihole without the query log      <UTC>.tar.age
#                     (pihole-FTL.db*), so lists, allow/deny entries and settings
#   portainer         tar of APPS_ROOT/portainer/data                              <UTC>.tar.age
#   koffan-db         sqlite3 .backup of APPS_ROOT/koffan/data/shopping.db         <UTC>.sqlite.age
#   n8n-db            sqlite3 .backup of APPS_ROOT/n8n/data/database.sqlite        <UTC>.sqlite.age
#   n8n-files         tar of APPS_ROOT/n8n/data without the database and without n8n's config file (binary data; the config file holds a copy of
#                     the encryption key, whose only copy is SSM)
#   couchdb           tar of APPS_ROOT/couchdb in the order CouchDB documents: data/.shards, data/shards, data/*.couch, then etc
#                     (the files are append-only, so a live copy is safe; tar's "file changed" exit 1 is tolerated)  <UTC>.tar.age
#   (Speedtest Tracker is deliberately not backed up: the history is disposable.)
#
# SQLite jobs (R19): the HOST sqlite3 runs AS THE APP'S UID (setpriv), never as root: root would create root-owned -wal/-shm files next to a
# live WAL database and lock the app out. The consistent copy goes to a private directory on a tmpfs (/dev/shm, mode 0700, owned by that
# uid) and the job FAILS if that is not a tmpfs, so no plaintext database ever touches the SD card (ADR-015). The copy must pass
# PRAGMA integrity_check, must be smaller than half of the free space of the staging tmpfs (measured with stat; the unit hides /proc/meminfo), and is removed on every exit path.
#
# Usage: sudo scripts/backup-apps.sh        (run nightly by scripts/systemd/home-lab-backup-apps.timer; also safe to run by hand)
#
# Each job is ONE stream: source | age -r <owner public key> | size count | aws s3 cp -. No plaintext copy ever touches a disk. A job
# whose every stage succeeded and whose object is not suspiciously small gets a tiny marker <object>.ok; an object without a marker is
# incomplete and must not be restored. A job whose app is not installed (directory or container missing) is skipped with a log line.
# The run goes on after a failed job (the others are still backed up), then exits 1 and sends ONE rate-limited alert naming the failed
# jobs. The last-success file /var/lib/home-lab/backup-apps.last is written only when every job that ran succeeded.
# Keys and identity: exactly as backup-authentik.sh (the Pi holds only the owner's age PUBLIC recipient; role home-lab-pi-host may only
# s3:PutObject under authentik/ and apps/). Configuration: BACKUP_S3_BUCKET and BACKUP_AGE_RECIPIENT in /etc/home-lab/aws.env.
# Overrides for tests: HOME_LAB_ETC_DIR, HOME_LAB_STATE_DIR, HOME_LAB_APPS_ROOT, HOME_LAB_BACKUP_MIN_BYTES (default 1024),
# HOME_LAB_STAGE_BASE (the tmpfs base for SQLite copies, default /dev/shm) and HOME_LAB_STAGE_FREE_BYTES (test hook for the free-space check).
# Runbooks: docs/runbooks/r17-apps.md, docs/runbooks/r19-apps.md (restore of the SQLite and CouchDB jobs).
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/alert.sh
. "$SCRIPT_DIR/lib/alert.sh"

REPO_DIR="$(repo_dir "${BASH_SOURCE[0]}")"
APPS_ROOT="${HOME_LAB_APPS_ROOT:-$(lab_env_get "$REPO_DIR/config/lab.env" APPS_ROOT /apps)}"
ENV_FILE="$ALERT_ETC_DIR/aws.env"
STATE_FILE="$ALERT_STATE_DIR/backup-apps.last"
MIN_BYTES="${HOME_LAB_BACKUP_MIN_BYTES:-1024}"
STAGE_BASE="${HOME_LAB_STAGE_BASE:-/dev/shm}"
PREFIX="apps"
UNIT="home-lab-backup-apps.service"
ALERT_KEY="backup-apps-failed"
host_label="$(hostname 2> /dev/null || echo pi)"

# job|kind|container-or-directory|item|exclude pattern (tar only, may be empty)
JOBS=(
  "linkwarden-db|pg|linkwarden-postgresql|lw_pg_password|"
  "linkwarden-data|tar|linkwarden|data|"
  "homeassistant|tar|homeassistant|config|home-assistant_v2.db*"
  "pihole|tar|pihole|etc-pihole|pihole-FTL.db*"
  "portainer|tar|portainer|data|"
  "koffan-db|sqlite|koffan|data/shopping.db|"
  "n8n-db|sqlite|n8n|data/database.sqlite|"
  "n8n-files|tar|n8n|data|database.sqlite*,config"
  "couchdb|couch|couchdb||"
)

TMP=""
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

first_line() { head -n 1 "$1" 2> /dev/null | tr -c '[:print:]' ' ' | cut -c1-200 || true; }
unit_hash() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# fail <reason>: a configuration problem that stops the whole run (log, alert once a day, exit 1).
fail() {
  local reason="$1" marker
  warn "backup-apps: $reason"
  if alert_send "$ALERT_KEY" "home-lab CRITICAL: app backups failed" \
    "$(printf 'Host: %s\nThe nightly app backups failed.\nReason: %s\nLook: journalctl -u %s -n 80\nWhat to do: docs/runbooks/r17-apps.md\n' "$host_label" "$reason" "$UNIT")"; then
    marker="$ALERT_STATE_DIR/.check-alerted-$(unit_hash "$UNIT")"
    : > "$marker" 2> /dev/null || true
  fi
  exit 1
}

if ! { mkdir -p "$ALERT_STATE_DIR" && chmod 0700 "$ALERT_STATE_DIR"; } 2> /dev/null; then die "cannot create $ALERT_STATE_DIR (run with sudo)"; fi
if command -v flock > /dev/null 2>&1 && exec 9> "$ALERT_STATE_DIR/.backup-apps.lock"; then
  flock -n 9 || {
    info "another app backup run holds the lock; skipping this one"
    exit 0
  }
fi
# A restore in progress: the same marker file as the Authentik backup (docs/runbooks/pi-recovery.md).
if [ -e "$ALERT_ETC_DIR/restore-pending" ]; then
  info "backup-apps: $ALERT_ETC_DIR/restore-pending exists (a restore is in progress): no backup taken"
  exit 0
fi

# ---------------------------------------------------------------- configuration (validated, nothing sourced)
[ -r "$ENV_FILE" ] || fail "cannot read $ENV_FILE (run with sudo)"
bucket="$(lab_env_get "$ENV_FILE" BACKUP_S3_BUCKET)"
recipient="$(lab_env_get "$ENV_FILE" BACKUP_AGE_RECIPIENT)"
ta="$(lab_env_get "$ENV_FILE" RA_TRUST_ANCHOR_ARN)"
profile="$(lab_env_get "$ENV_FILE" RA_HOST_PROFILE_ARN)"
role="$(lab_env_get "$ENV_FILE" RA_HOST_ROLE_ARN)"
region="$(lab_env_get "$ENV_FILE" AWS_REGION af-south-1)"
[[ "$recipient" =~ ^age1[02-9ac-hj-np-z]{58}$ ]] || fail "BACKUP_AGE_RECIPIENT is missing or not an age public key (age1...) in $ENV_FILE"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail "BACKUP_S3_BUCKET is missing or malformed in $ENV_FILE"
[[ "$ta" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:trust-anchor/[0-9a-f-]+$ ]] || fail "RA_TRUST_ANCHOR_ARN in $ENV_FILE is missing or malformed"
[[ "$profile" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:profile/[0-9a-f-]+$ ]] || fail "RA_HOST_PROFILE_ARN in $ENV_FILE is missing or malformed"
[[ "$role" =~ ^arn:aws[a-z-]*:iam::[0-9]+:role/[A-Za-z0-9+=,.@_/-]+$ ]] || fail "RA_HOST_ROLE_ARN in $ENV_FILE is missing or malformed"
[[ "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || fail "AWS_REGION in $ENV_FILE is malformed"
[[ "$MIN_BYTES" =~ ^[0-9]{1,9}$ ]] || fail "HOME_LAB_BACKUP_MIN_BYTES is not a number"
{ [ -r "$ALERT_ETC_DIR/pki/host.crt" ] && [ -r "$ALERT_ETC_DIR/pki/host.key" ]; } || fail "host certificate or key missing in $ALERT_ETC_DIR/pki"
for t in docker age aws dd tar; do
  command -v "$t" > /dev/null 2>&1 || fail "$t is not installed"
done

TMP="$(mktemp -d)"
chmod 0700 "$TMP"
cat > "$TMP/aws-config" << CFG
[profile home-lab-host]
region = $region
credential_process = /usr/local/bin/aws_signing_helper credential-process --certificate $ALERT_ETC_DIR/pki/host.crt --private-key $ALERT_ETC_DIR/pki/host.key --trust-anchor-arn $ta --profile-arn $profile --role-arn $role --session-duration 3600
CFG
chmod 0600 "$TMP/aws-config"
aws_put() { # aws_put <s3 url>: stdin to the object, as the host role, from the private profile
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_DEFAULT_PROFILE \
    HOME="$TMP" AWS_CONFIG_FILE="$TMP/aws-config" AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=home-lab-host \
    AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" \
    aws s3 cp - "$1" --no-progress --only-show-errors --region "$region" --no-cli-pager
}

# shellcheck source=lib/backup-streams.sh
. "$SCRIPT_DIR/lib/backup-streams.sh"

# source_of <kind> <where> <item> <exclude>: the plaintext stream of one job on stdout.
source_of() {
  case "$1" in
    sqlite) sqlite_stream "$2" "$3" ;;
    couch) couch_stream "$2" ;;
    pg)
      # The password is read inside the container from its own secret file; POSTGRES_USER and POSTGRES_DB are the container's settings.
      # shellcheck disable=SC2016 # expanded INSIDE the container, on purpose
      docker exec "$2" sh -c 'PGPASSWORD="$(cat "/run/secrets/'"$3"'")" exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc'
      ;;
    tar)
      # $4 may hold several exclude patterns, comma separated (relative to the item)
      local ex=() p
      if [ -n "$4" ]; then
        IFS=',' read -r -a pats <<< "$4"
        for p in "${pats[@]}"; do ex+=(--exclude="$3/$p"); done
      fi
      tar -C "$APPS_ROOT/$2" --anchored "${ex[@]}" -cf - "$3"
      ;;
  esac
}

export LC_ALL=C
ts="$(date -u +%Y%m%dT%H%M%SZ)"
failed=()
done_jobs=()
for spec in "${JOBS[@]}"; do
  IFS='|' read -r job kind where item exclude <<< "$spec"
  if [ "$kind" = pg ]; then
    if ! docker inspect "$where" > /dev/null 2>&1; then
      info "backup-apps: $job skipped ($where is not installed)"
      continue
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "$where" 2> /dev/null || true)" = true ] || {
      warn "backup-apps: $job FAILED: the container $where is not running"
      failed+=("$job (container not running)")
      continue
    }
    ext=dump
  elif [ "$kind" = sqlite ]; then
    if [ ! -f "$APPS_ROOT/$where/$item" ]; then
      info "backup-apps: $job skipped ($APPS_ROOT/$where/$item does not exist)"
      continue
    fi
    ext=sqlite
  elif [ "$kind" = couch ]; then
    if [ ! -d "$APPS_ROOT/$where/data" ]; then
      info "backup-apps: $job skipped ($APPS_ROOT/$where/data does not exist)"
      continue
    fi
    ext=tar
  else
    if [ ! -d "$APPS_ROOT/$where/$item" ]; then
      info "backup-apps: $job skipped ($APPS_ROOT/$where/$item does not exist)"
      continue
    fi
    ext=tar
  fi
  key="$PREFIX/$job/$ts.$ext.age"
  set +e
  source_of "$kind" "$where" "$item" "$exclude" 2> "$TMP/src.err" |
    age -r "$recipient" 2> "$TMP/age.err" |
    dd bs=65536 2> "$TMP/dd.err" |
    aws_put "s3://$bucket/$key" 2> "$TMP/aws.err"
  rcs=("${PIPESTATUS[@]}")
  set -e
  why=""
  if [ "${#rcs[@]}" -ne 4 ]; then
    why="internal error (${#rcs[@]} pipeline stages)"
  elif [ "${rcs[3]}" -ne 0 ]; then
    why="S3 upload failed: $(first_line "$TMP/aws.err")"
  elif [ "${rcs[2]}" -ne 0 ]; then
    why="size counter failed"
  elif [ "${rcs[1]}" -ne 0 ]; then
    why="age encryption failed: $(first_line "$TMP/age.err")"
  elif [ "${rcs[0]}" -ne 0 ]; then
    why="the source ($kind) failed with exit ${rcs[0]}: $(first_line "$TMP/src.err")"
  fi
  bytes="$(grep -oE '^[0-9]+ bytes' "$TMP/dd.err" 2> /dev/null | head -n 1 | cut -d' ' -f1 || true)"
  if [ -z "$why" ] && ! [[ "$bytes" =~ ^[0-9]+$ ]]; then why="could not measure the size"; fi
  if [ -z "$why" ] && [ "$bytes" -lt "$MIN_BYTES" ]; then why="only $bytes bytes (minimum $MIN_BYTES): empty or truncated"; fi
  if [ -z "$why" ]; then
    if printf 'bytes=%s\nutc=%s\n' "$bytes" "$ts" | aws_put "s3://$bucket/$key.ok" 2> "$TMP/aws.err"; then
      info "backup-apps: $job OK, $bytes bytes as $key (marker written)"
      done_jobs+=("$job")
      continue
    fi
    why="uploading the completion marker failed: $(first_line "$TMP/aws.err")"
  fi
  warn "backup-apps: $job FAILED: $why (the object has no marker and must not be used)"
  failed+=("$job ($why)")
done

if [ "${#failed[@]}" -gt 0 ]; then
  fail "$(printf '%s; ' "${failed[@]}")succeeded: ${done_jobs[*]:-none}"
fi
now="$(date +%s)"
if ! { printf '%s\n' "$now" > "$STATE_FILE.new" && mv -f "$STATE_FILE.new" "$STATE_FILE"; }; then fail "could not record the success time in $STATE_FILE"; fi
info "backup-apps: OK (${done_jobs[*]:-no app installed yet})"
