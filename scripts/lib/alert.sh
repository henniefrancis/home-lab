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
    warn "alert: ALERT_TOPIC_ARN is missing or malformed in $env_file (terraform output alert_topic_arn, see docs/runbooks/alerting.md)"
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
  subject="$(printf '%s' "$subject" | tr -c '[:print:]' ' ' | cut -c1-100)"
  message="$(printf '%s' "$message" | head -c 4000)"

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
    aws sns publish --topic-arn "$topic" --subject "$subject" --message "$message" \
    --query MessageId --output text --region "$region" --no-cli-pager 2>&1)" || rc=$?
  rm -rf "$tmp"
  if [ "$rc" -ne 0 ]; then
    warn "alert: publish failed: $(printf '%s' "$out" | head -n 1 | cut -c1-200)"
    return 1
  fi
  printf 'alert published (SNS message id %s)\n' "$(printf '%s' "$out" | head -n 1 | cut -c1-64)"
}

# alert_send <key> <subject> <message>: rate limited publish. Returns 0 when sent OR suppressed (nothing more to do), 1 on failure.
alert_send() {
  local key="$1" subject="$2" message="$3" f last now
  [[ "$key" =~ ^[a-z0-9-]{1,40}$ ]] || {
    warn "alert: bad key '$key'"
    return 1
  }
  f="$ALERT_STATE_DIR/alert-$key.last"
  now="$(date +%s)"
  if [ -r "$f" ]; then
    last="$(cat "$f" 2> /dev/null || true)"
    if [[ "$last" =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$ALERT_INTERVAL" ]; then
      printf 'alert for %s suppressed: one was sent %d minutes ago (limit: one per %d hours)\n' "$key" $(((now - last) / 60)) $((ALERT_INTERVAL / 3600))
      return 0
    fi
  fi
  { mkdir -p "$ALERT_STATE_DIR" && chmod 0700 "$ALERT_STATE_DIR"; } 2> /dev/null || {
    warn "alert: cannot create $ALERT_STATE_DIR"
    return 1
  }
  alert_publish "$subject" "$message" || return 1
  printf '%s\n' "$now" > "$f.new" && mv -f "$f.new" "$f"
}
