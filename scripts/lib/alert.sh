#!/usr/bin/env bash
# shellcheck shell=bash
# Alert helpers for the Pi (K4). Source it; do not execute it.
#
# alert_send <key> <subject> <message>   publish to the SNS topic, at most once per <key> per 24 hours (state file under the state dir)
# alert_publish <subject> <message>      publish now, no rate limit (used by `alert.sh test`)
#
# Identity: the same Roles Anywhere profile fetch-secrets.sh uses (role home-lab-pi-host, which may sns:Publish on the one alert
# topic and nothing else). The AWS profile is written to a private temporary directory that is removed on return. Credentials are
# never printed: the helper's output goes to the AWS CLI, not to this script, and AWS error text is trimmed to one line.
# Configuration (root-only /etc/home-lab/aws.env): ALERT_TOPIC_ARN (from `terraform output alert_topic_arn`, scripts/render-aws-env.sh),
# RA_TRUST_ANCHOR_ARN, RA_HOST_PROFILE_ARN, RA_HOST_ROLE_ARN, AWS_REGION.
# Overrides for tests: HOME_LAB_ETC_DIR, HOME_LAB_STATE_DIR, HOME_LAB_ALERT_INTERVAL (seconds, default 86400).
# Needs common.sh (warn, lab_env_get) to be sourced first.

ALERT_ETC_DIR="${HOME_LAB_ETC_DIR:-/etc/home-lab}"
ALERT_STATE_DIR="${HOME_LAB_STATE_DIR:-/var/lib/home-lab}"
ALERT_INTERVAL="${HOME_LAB_ALERT_INTERVAL:-86400}"
# The timer has RandomizedDelaySec=1h, so a run can come up to an hour earlier than yesterday's: allow slack, so the cadence is
# daily, not 24 to 48 hours (QA-L-1). Override for tests: HOME_LAB_ALERT_SLACK (seconds).
ALERT_SLACK="${HOME_LAB_ALERT_SLACK:-7200}"

ALERT_TOPIC_RE='^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$'

# alert_topic: print the configured topic ARN, or nothing when unset or malformed.
alert_topic() {
  local t
  t="$(lab_env_get "$ALERT_ETC_DIR/aws.env" ALERT_TOPIC_ARN)"
  if [[ "$t" =~ $ALERT_TOPIC_RE ]]; then printf '%s' "$t"; fi
  return 0
}

# alert_publish <subject> <message>: 0 on success, 1 not configured or publish failed (reason on stderr, never a credential).
alert_publish() {
  local subject="$1" message="$2" env_file="$ALERT_ETC_DIR/aws.env" topic ta profile role region tmp out rc=0
  command -v aws > /dev/null 2>&1 || {
    warn "alert: aws CLI not installed"
    return 1
  }
  [ -r "$env_file" ] || {
    warn "alert: cannot read $env_file (run with sudo)"
    return 1
  }
  topic="$(alert_topic)"
  [ -n "$topic" ] || {
    warn "alert: ALERT_TOPIC_ARN is missing or malformed in $env_file (no quotes or spaces; value from terraform output alert_topic_arn, see docs/runbooks/alerting.md)"
    return 1
  }
  ta="$(lab_env_get "$env_file" RA_TRUST_ANCHOR_ARN)"
  profile="$(lab_env_get "$env_file" RA_HOST_PROFILE_ARN)"
  role="$(lab_env_get "$env_file" RA_HOST_ROLE_ARN)"
  region="$(lab_env_get "$env_file" AWS_REGION af-south-1)"
  [[ "$ta" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:trust-anchor/[0-9a-f-]+$ ]] || {
    warn "alert: RA_TRUST_ANCHOR_ARN in $env_file is missing or malformed"
    return 1
  }
  [[ "$profile" =~ ^arn:aws[a-z-]*:rolesanywhere:[a-z0-9-]+:[0-9]+:profile/[0-9a-f-]+$ ]] || {
    warn "alert: RA_HOST_PROFILE_ARN in $env_file is missing or malformed"
    return 1
  }
  [[ "$role" =~ ^arn:aws[a-z-]*:iam::[0-9]+:role/[A-Za-z0-9+=,.@_/-]+$ ]] || {
    warn "alert: RA_HOST_ROLE_ARN in $env_file is missing or malformed"
    return 1
  }
  [[ "$region" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || {
    warn "alert: AWS_REGION in $env_file is malformed"
    return 1
  }
  { [ -r "$ALERT_ETC_DIR/pki/host.crt" ] && [ -r "$ALERT_ETC_DIR/pki/host.key" ]; } || {
    warn "alert: host certificate or key missing in $ALERT_ETC_DIR/pki"
    return 1
  }
  # SNS limits: subject 100 ASCII characters on one line, message 256 KB. Keep both short and plain.
  # SEC-L-7: both values start with fixed text (never "-" or "file://") and are passed as --option=value.
  case "$subject" in home-lab*) ;; *) subject="home-lab: $subject" ;; esac
  subject="$(printf '%s' "$subject" | tr -c '[:print:]' ' ' | cut -c1-100)"
  message="$(printf 'home-lab alert\n%s' "$message" | head -c 4000)"

  tmp="$(mktemp -d)"
  chmod 0700 "$tmp"
  cat > "$tmp/aws-config" << CFG
[profile home-lab-host]
region = $region
credential_process = /usr/local/bin/aws_signing_helper credential-process --certificate $ALERT_ETC_DIR/pki/host.crt --private-key $ALERT_ETC_DIR/pki/host.key --trust-anchor-arn $ta --profile-arn $profile --role-arn $role --session-duration 3600
CFG
  chmod 0600 "$tmp/aws-config"
  out="$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_DEFAULT_PROFILE \
    HOME="$tmp" AWS_CONFIG_FILE="$tmp/aws-config" AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=home-lab-host \
    AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" \
    aws sns publish --topic-arn "$topic" --subject="$subject" --message="$message" \
    --query MessageId --output text --region "$region" --no-cli-pager 2>&1)" || rc=$?
  rm -rf "$tmp"
  if [ "$rc" -ne 0 ]; then
    warn "alert: publish failed: $(printf '%s' "$out" | head -n 1 | cut -c1-200)"
    return 1
  fi
  printf 'alert published (SNS message id %s)\n' "$(printf '%s' "$out" | head -n 1 | cut -c1-64)"
}

# alert_last_sent <file> <now>: print the epoch of the last alert from a state file, or nothing when the file is missing or its
# content is not trustworthy (not plain decimal digits, more than 11 digits, in the future, which a Pi with no RTC can write, QA-M-2).
# The value is converted with 10# so a leading zero is never read as octal (QA-L-6).
alert_last_sent() {
  local last
  last="$(head -c 20 "$1" 2> /dev/null | tr -d '\n' || true)"
  [[ "$last" =~ ^[0-9]{1,11}$ ]] || return 0
  last=$((10#$last))
  [ "$last" -le "$2" ] || return 0
  printf '%s' "$last"
}

# alert_send <key> <subject> <message>: rate limited publish (one per key per interval, minus slack). Returns 0 when sent OR
# suppressed (nothing more to do), 1 on failure. A lock makes check, publish and state write one step, so two parallel runs for
# one key cannot both publish (QA-L-7).
alert_send() {
  local key="$1" subject="$2" message="$3" f last now rc=0
  [[ "$key" =~ ^[a-z0-9-]{1,60}$ ]] || {
    warn "alert: bad key '$key'"
    return 1
  }
  { mkdir -p "$ALERT_STATE_DIR" && chmod 0700 "$ALERT_STATE_DIR"; } 2> /dev/null || {
    warn "alert: cannot create $ALERT_STATE_DIR"
    return 1
  }
  if command -v flock > /dev/null 2>&1 && exec 8> "$ALERT_STATE_DIR/.lock"; then
    flock -w 120 8 || warn "alert: could not take the lock; continuing without it"
  fi
  f="$ALERT_STATE_DIR/alert-$key.last"
  now="$(date +%s)"
  last="$(alert_last_sent "$f" "$now")"
  if [ -n "$last" ] && [ $((now - last + ALERT_SLACK)) -lt "$ALERT_INTERVAL" ]; then
    printf 'alert for %s suppressed: one was sent %d minutes ago (limit: one per %d hours)\n' "$key" $(((now - last) / 60)) $((ALERT_INTERVAL / 3600))
  elif alert_publish "$subject" "$message"; then
    printf '%s\n' "$now" > "$f.new" && mv -f "$f.new" "$f"
  else
    rc=1
  fi
  exec 8>&-
  return "$rc"
}
