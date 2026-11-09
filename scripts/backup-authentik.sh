#!/usr/bin/env bash
# backup-authentik.sh - Pi, root: encrypted off-Pi backup of the Authentik database (K5, ADR-015).
#
# Usage: sudo scripts/backup-authentik.sh        (run nightly by scripts/systemd/home-lab-backup-authentik.timer; also safe to run by hand)
#
# What it does, as ONE stream, so no plaintext dump ever touches a disk:
#   docker exec authentik-postgresql pg_dump -Fc  |  age -r <owner public key>  |  size count  |  aws s3 cp - s3://<bucket>/authentik/<UTC>.dump.age
# Then, only when every stage succeeded and the object is not suspiciously small, it uploads a tiny marker <UTC>.dump.age.ok (byte count)
# and records the success time in /var/lib/home-lab/backup-authentik.last (an epoch, written atomically). A dump object WITHOUT a marker
# is incomplete or suspect: the Pi role cannot delete it (write-only by design), so the marker is how a restore picks a good one.
#
# Keys: the Pi holds only the owner's age PUBLIC recipient (BACKUP_AGE_RECIPIENT, non-secret). The private identity lives only in the
# owner's password manager; a stolen Pi can neither read nor delete a backup. The database password is read INSIDE the container from
# its own secret file and never leaves it (not printed, not on a command line, not in an environment of this host).
# Identity to AWS: the same Roles Anywhere profile as fetch-secrets.sh and alert.sh (role home-lab-pi-host, which may s3:PutObject under
# authentik/ and nothing else). The AWS profile is written to a private 0700 temporary directory that is removed on exit.
# Configuration (root-only /etc/home-lab/aws.env): BACKUP_S3_BUCKET (terraform output backup_bucket_name), BACKUP_AGE_RECIPIENT (age1...),
# plus the RA_* values and AWS_REGION that alert.sh uses (scripts/render-aws-env.sh prints them).
# On failure: exit 1 (the systemd unit fails), one rate-limited alert per day (key backup-authentik-failed, scripts/lib/alert.sh), and no
# change to the last-success file.
# Overrides for tests: HOME_LAB_ETC_DIR, HOME_LAB_STATE_DIR, HOME_LAB_BACKUP_CONTAINER, HOME_LAB_BACKUP_MIN_BYTES (default 4096).
# Runbook: docs/runbooks/authentik-backup.md.
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/alert.sh
. "$SCRIPT_DIR/lib/alert.sh"

ENV_FILE="$ALERT_ETC_DIR/aws.env"
STATE_FILE="$ALERT_STATE_DIR/backup-authentik.last"
CONTAINER="${HOME_LAB_BACKUP_CONTAINER:-authentik-postgresql}"
MIN_BYTES="${HOME_LAB_BACKUP_MIN_BYTES:-4096}"
PREFIX="authentik"
UNIT="home-lab-backup-authentik.service"
ALERT_KEY="backup-authentik-failed"
host_label="$(hostname 2> /dev/null || echo pi)"

TMP=""
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

# first_line <file>: the first line of a file, printable characters only, at most 200 characters (never a credential: AWS and pg_dump
# error text names an operation and a reason).
first_line() { head -n 1 "$1" 2> /dev/null | tr -c '[:print:]' ' ' | cut -c1-200 || true; }

unit_hash() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# fail <reason>: log, alert once a day, remember that the specific alert went out (so the OnFailure= handler does not mail a second
# time, the same marker alert.sh check uses), exit 1.
fail() {
  local reason="$1" marker
  warn "backup-authentik: $reason"
  if alert_send "$ALERT_KEY" "home-lab CRITICAL: Authentik backup failed" \
    "$(printf 'Host: %s\nThe nightly Authentik database backup failed.\nReason: %s\nLook: journalctl -u %s -n 50\nWhat to do: docs/runbooks/authentik-backup.md\n' "$host_label" "$reason" "$UNIT")"; then
    marker="$ALERT_STATE_DIR/.check-alerted-$(unit_hash "$UNIT")"
    : > "$marker" 2> /dev/null || true
  fi
  exit 1
}

if ! { mkdir -p "$ALERT_STATE_DIR" && chmod 0700 "$ALERT_STATE_DIR"; } 2> /dev/null; then die "cannot create $ALERT_STATE_DIR (run with sudo)"; fi

# One run at a time (a manual start while the timer fires would otherwise upload two dumps and fight over the state file).
if command -v flock > /dev/null 2>&1 && exec 9> "$ALERT_STATE_DIR/.backup.lock"; then
  flock -n 9 || {
    info "another backup run holds the lock; skipping this one"
    exit 0
  }
fi

# ---------------------------------------------------------------- configuration (validated, nothing sourced)
[ -r "$ENV_FILE" ] || fail "cannot read $ENV_FILE (run with sudo)"
bucket="$(lab_env_get "$ENV_FILE" BACKUP_S3_BUCKET)"
recipient="$(lab_env_get "$ENV_FILE" BACKUP_AGE_RECIPIENT)"
ta="$(lab_env_get "$ENV_FILE" RA_TRUST_ANCHOR_ARN)"
profile="$(lab_env_get "$ENV_FILE" RA_HOST_PROFILE_ARN)"
role="$(lab_env_get "$ENV_FILE" RA_HOST_ROLE_ARN)"
region="$(lab_env_get "$ENV_FILE" AWS_REGION af-south-1)"

# Bech32 characters only (no 1, b, i, o after the separator): an age X25519 recipient is "age1" plus 58 of them.
[[ "$recipient" =~ ^age1[02-9ac-hj-np-z]{58}$ ]] || fail "BACKUP_AGE_RECIPIENT is missing or not an age public key (age1...) in $ENV_FILE: no backup taken (docs/runbooks/authentik-backup.md, owner setup)"
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail "BACKUP_S3_BUCKET is missing or malformed in $ENV_FILE (terraform output backup_bucket_name)"
[[ "$ta" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:trust-anchor/[0-9a-f-]+$ ]] || fail "RA_TRUST_ANCHOR_ARN in $ENV_FILE is missing or malformed"
[[ "$profile" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:profile/[0-9a-f-]+$ ]] || fail "RA_HOST_PROFILE_ARN in $ENV_FILE is missing or malformed"
[[ "$role" =~ ^arn:aws[a-z-]*:iam::[0-9]+:role/[A-Za-z0-9+=,.@_/-]+$ ]] || fail "RA_HOST_ROLE_ARN in $ENV_FILE is missing or malformed"
[[ "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || fail "AWS_REGION in $ENV_FILE is malformed"
[[ "$CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || fail "the database container name is malformed"
[[ "$MIN_BYTES" =~ ^[0-9]{1,9}$ ]] || fail "HOME_LAB_BACKUP_MIN_BYTES is not a number"
{ [ -r "$ALERT_ETC_DIR/pki/host.crt" ] && [ -r "$ALERT_ETC_DIR/pki/host.key" ]; } || fail "host certificate or key missing in $ALERT_ETC_DIR/pki"
for t in docker age aws dd; do
  command -v "$t" > /dev/null 2>&1 || fail "$t is not installed (sudo scripts/bootstrap.sh installs age; docker and aws come from the earlier setup steps)"
done
[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2> /dev/null || true)" = true ] || fail "the database container $CONTAINER is not running"

# ---------------------------------------------------------------- the one stream
TMP="$(mktemp -d)"
chmod 0700 "$TMP"
cat > "$TMP/aws-config" << CFG
[profile home-lab-host]
region = $region
credential_process = /usr/local/bin/aws_signing_helper credential-process --certificate $ALERT_ETC_DIR/pki/host.crt --private-key $ALERT_ETC_DIR/pki/host.key --trust-anchor-arn $ta --profile-arn $profile --role-arn $role --session-duration 3600
CFG
chmod 0600 "$TMP/aws-config"
aws_put() { # aws_put <s3 url>: copy stdin to the object, as the host role, from the private profile
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_DEFAULT_PROFILE \
    HOME="$TMP" AWS_CONFIG_FILE="$TMP/aws-config" AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=home-lab-host \
    AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" \
    aws s3 cp - "$1" --no-progress --only-show-errors --region "$region" --no-cli-pager
}

ts="$(date -u +%Y%m%dT%H%M%SZ)"
key="$PREFIX/$ts.dump.age"
info "backup-authentik: dumping $CONTAINER to s3://$bucket/$key (encrypted on this host first)"

# The password is read inside the container from its own secret file; POSTGRES_USER and POSTGRES_DB are the container's own settings.
# stdout of the container command is the custom-format dump (binary, no TTY, no stdin).
# shellcheck disable=SC2016 # the variables are expanded by the shell INSIDE the container, on purpose
pg_cmd='PGPASSWORD="$(cat /run/secrets/pg_password)" exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc'
# `set +e` around the pipeline only: every stage's exit code is read from PIPESTATUS, and one failing stage fails the run.
export LC_ALL=C
set +e
docker exec "$CONTAINER" sh -c "$pg_cmd" 2> "$TMP/pg.err" |
  age -r "$recipient" 2> "$TMP/age.err" |
  dd bs=65536 2> "$TMP/dd.err" |
  aws_put "s3://$bucket/$key" 2> "$TMP/aws.err"
rcs=("${PIPESTATUS[@]}")
set -e

if [ "${#rcs[@]}" -ne 4 ]; then fail "internal error: the pipeline reported ${#rcs[@]} stages, expected 4"; fi
# Judge from the LAST stage back: when a later stage dies first (age cannot encrypt, S3 refuses), the stages before it only see a broken
# pipe (exit 141), so the last failing stage is the cause. A pg_dump that fails on its own leaves every later stage "successful" on a
# truncated stream, which is why its exit code is checked too and why a failed run never writes the marker.
[ "${rcs[3]}" -eq 0 ] || fail "the S3 upload failed (exit ${rcs[3]}): $(first_line "$TMP/aws.err")"
[ "${rcs[2]}" -eq 0 ] || fail "the size counter failed (exit ${rcs[2]})"
[ "${rcs[1]}" -eq 0 ] || fail "age encryption failed (exit ${rcs[1]}): $(first_line "$TMP/age.err")"
[ "${rcs[0]}" -eq 0 ] || fail "pg_dump failed (exit ${rcs[0]}; the object may be incomplete and has no marker): $(first_line "$TMP/pg.err")"

bytes="$(grep -oE '^[0-9]+ bytes' "$TMP/dd.err" 2> /dev/null | head -n 1 | cut -d' ' -f1 || true)"
[[ "$bytes" =~ ^[0-9]+$ ]] || fail "could not measure the size of the uploaded backup"
[ "$bytes" -ge "$MIN_BYTES" ] || fail "the backup is only $bytes bytes (minimum $MIN_BYTES): the dump is empty or truncated; the object s3://$bucket/$key has no marker and must not be used"

# Marker: proof that the object above is complete. Written only now, so an interrupted or truncated upload never has one.
printf 'bytes=%s\nutc=%s\n' "$bytes" "$ts" | aws_put "s3://$bucket/$key.ok" 2> "$TMP/aws.err" || fail "uploading the completion marker failed: $(first_line "$TMP/aws.err")"

# Last success, atomically (write a new file in the same directory, then rename).
now="$(date +%s)"
if ! { printf '%s\n' "$now" > "$STATE_FILE.new" && mv -f "$STATE_FILE.new" "$STATE_FILE"; }; then fail "could not record the success time in $STATE_FILE"; fi
info "backup-authentik: OK, $bytes bytes uploaded as $key (marker written)"
