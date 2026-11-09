#!/usr/bin/env bash
# test-aws-preflight.sh - runs scripts/aws-preflight.sh --snapshot end to end against a MOCK aws (QA-L-12, NEW-15, NEW-12).
# Needs jq. Never contacts AWS, HCP or the network: aws, terraform and dig are stubs placed first on PATH, the AWS config and
# credentials are disabled, and the test PROVES the mock is the aws that will run (marker call) before any case; it aborts otherwise.
# Covers: carriage returns (the mock answers with CRLF like aws.exe), an empty duplicate-zone list (must be [], never [""]),
# a real duplicate zone, TXT quote handling, HCL escaping of the zone comment and of record values, and the SSM warning text.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose: $1, $2 expand in the child shell
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
command -v jq > /dev/null || {
  echo "jq is required" >&2
  exit 2
}

fails=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  fails=$((fails + 1))
}
check() { # check <description> <command...>
  local d="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/data"

# ---------------------------------------------------------------- canned answers (pretty-printed on purpose: many line ends)
cat > "$T/data/sts.json" << 'JSON'
{
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/test-role/session"
}
JSON
cat > "$T/data/domain.json" << 'JSON'
{
  "Nameservers": [{"Name": "ns-1.example.org"}, {"Name": "ns-2.example.org"}],
  "AutoRenew": true,
  "TransferLock": true,
  "AdminPrivacy": true,
  "RegistrantPrivacy": true,
  "TechPrivacy": true,
  "ExpirationDate": "2030-01-01T00:00:00Z",
  "DnssecKeys": []
}
JSON
cat > "$T/data/zones-one.json" << 'JSON'
{
  "HostedZones": [
    {"Id": "/hostedzone/Z1AAAAAAAAAAAAAAAAAA", "Name": "example.test.", "Config": {"PrivateZone": false}}
  ]
}
JSON
cat > "$T/data/zones-dup.json" << 'JSON'
{
  "HostedZones": [
    {"Id": "/hostedzone/Z1AAAAAAAAAAAAAAAAAA", "Name": "example.test.", "Config": {"PrivateZone": false}},
    {"Id": "/hostedzone/Z2BBBBBBBBBBBBBBBBBB", "Name": "example.test.", "Config": {"PrivateZone": false}}
  ]
}
JSON
cat > "$T/data/zone-Z1AAAAAAAAAAAAAAAAAA.json" << 'JSON'
{
  "HostedZone": {
    "Id": "/hostedzone/Z1AAAAAAAAAAAAAAAAAA",
    "Config": {"Comment": "owner ${x} and %{y} comment"},
    "ResourceRecordSetCount": 4
  },
  "DelegationSet": {"NameServers": ["ns-1.example.org", "ns-2.example.org"]}
}
JSON
cat > "$T/data/zone-Z2BBBBBBBBBBBBBBBBBB.json" << 'JSON'
{
  "HostedZone": {
    "Id": "/hostedzone/Z2BBBBBBBBBBBBBBBBBB",
    "Config": {"Comment": "stray duplicate"},
    "ResourceRecordSetCount": 2
  },
  "DelegationSet": {"NameServers": ["ns-9.example.net", "ns-8.example.net"]}
}
JSON
cat > "$T/data/rrs-Z1AAAAAAAAAAAAAAAAAA.json" << 'JSON'
{
  "ResourceRecordSets": [
    {"Name": "example.test.", "Type": "NS", "TTL": 172800, "ResourceRecords": [{"Value": "ns-1.example.org."}]},
    {"Name": "example.test.", "Type": "SOA", "TTL": 900, "ResourceRecords": [{"Value": "ns-1.example.org. hostmaster.example.org. 1 7200 900 1209600 86400"}]},
    {"Name": "spf.example.test.", "Type": "TXT", "TTL": 300, "ResourceRecords": [{"Value": "\"v=spf1 include:x ${y} -all\""}]},
    {"Name": "multi.example.test.", "Type": "TXT", "TTL": 300, "ResourceRecords": [{"Value": "\"part-one\" \"part-two\""}]},
    {"Name": "\\052.example.test.", "Type": "A", "TTL": 60, "ResourceRecords": [{"Value": "192.0.2.10"}]}
  ]
}
JSON
cat > "$T/data/rrs-Z2BBBBBBBBBBBBBBBBBB.json" << 'JSON'
{
  "ResourceRecordSets": [
    {"Name": "example.test.", "Type": "NS", "TTL": 172800, "ResourceRecords": [{"Value": "ns-9.example.net."}]},
    {"Name": "example.test.", "Type": "SOA", "TTL": 900, "ResourceRecords": [{"Value": "ns-9.example.net. h.example.net. 1 7200 900 1209600 86400"}]}
  ]
}
JSON

# ---------------------------------------------------------------- the stubs
cat > "$T/bin/aws" << 'MOCK'
#!/usr/bin/env bash
# MOCK aws for test-aws-preflight.sh: canned answers from $MOCK_DATA, every line ending in CRLF like aws.exe on Windows.
args="$*"
crlf() { sed 's/$/\r/'; }
zid() { printf '%s' "$args" | sed -n "s/.*$1 \([A-Z0-9]*\).*/\1/p"; }
case "$args" in
  *"--mock-marker"*) echo MOCK-AWS-MARKER | crlf ;;
  *"--version"*) echo "aws-cli/2.17.0 Python/3.12.0 Linux/test" | crlf ;;
  *"sts get-caller-identity"*) crlf < "$MOCK_DATA/sts.json" ;;
  *"account get-region-opt-status"*) echo ENABLED | crlf ;;
  *"rolesanywhere list-trust-anchors"*) echo '{"trustAnchors": []}' | crlf ;;
  *"route53domains get-domain-detail"*) crlf < "$MOCK_DATA/domain.json" ;;
  *"route53 list-hosted-zones-by-name"*) crlf < "$MOCK_DATA/${MOCK_ZONES:-zones-one}.json" ;;
  *"route53 get-hosted-zone"*) crlf < "$MOCK_DATA/zone-$(zid -id).json" ;;
  *"route53 list-tags-for-resource"*) echo '[]' | crlf ;;
  *"route53 list-resource-record-sets"*) crlf < "$MOCK_DATA/rrs-$(zid -hosted-zone-id).json" ;;
  *"ssm describe-parameters"*) printf '%s\n' "${MOCK_SSM:-}" | crlf ;;
  *) exit 255 ;; # everything else: not found / not allowed, which the script treats as a WARN
esac
exit 0
MOCK
printf '#!/bin/sh\ncase "$*" in *-json*) echo "{\\"terraform_version\\": \\"1.17.1\\"}" ;; *) echo "Terraform v1.17.1" ;; esac\n' > "$T/bin/terraform"
printf '#!/bin/sh\ncase "$*" in *" NS "*) printf "ns-1.example.org\\nns-2.example.org\\n" ;; esac\nexit 0\n' > "$T/bin/dig"
chmod +x "$T/bin/aws" "$T/bin/terraform" "$T/bin/dig"

export MOCK_DATA="$T/data"
export PATH="$T/bin:$PATH"
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=does-not-exist AWS_EC2_METADATA_DISABLED=true
export AWS_PROFILE_NAME=mock-profile
unset TF_CLOUD_ORGANIZATION TF_TOKEN_app_terraform_io # nothing may reach HCP: no organization, no token, so no terraform init

# PROOF that the mock, not a real CLI, will run (aborts the whole test otherwise).
case "$(command -v aws)" in
  "$T"/bin/aws) ;;
  *)
    echo "ABORT: aws on PATH is not the mock" >&2
    exit 3
    ;;
esac
[ "$(aws --mock-marker | tr -d '\r')" = MOCK-AWS-MARKER ] || {
  echo "ABORT: the mock marker call did not answer" >&2
  exit 3
}
[ "$(command -v terraform)" = "$T/bin/terraform" ] && [ "$(command -v dig)" = "$T/bin/dig" ] || {
  echo "ABORT: terraform or dig is not the stub" >&2
  exit 3
}
# the mock really emits carriage returns (otherwise this test would prove nothing about them)
crs() { tr -cd '\r' | wc -c | tr -d ' '; } # number of carriage returns on stdin (grep on MSYS hides them)
export -f crs
[ "$(aws sts get-caller-identity | crs)" -gt 0 ] || {
  echo "ABORT: the mock does not emit CRLF" >&2
  exit 3
}

preflight() { # preflight <snapshot dir> [env assignments...]: output in $T/out (the exit code is 1 here: HCP is deliberately not configured)
  local d="$1"
  shift
  env "$@" DOMAIN=example.test SNAPSHOT_DIR="$d" bash scripts/aws-preflight.sh --snapshot > "$T/out" 2>&1 || true
}

# ---------------------------------------------------------------- case 1: one delegated zone, no duplicates
preflight "$T/snap1" MOCK_ZONES=zones-one
check "the snapshot is written (the exit code is 1 only because HCP Terraform is deliberately not configured)" bash -c 'test -s "$1/scalar-variables.txt" && test -s "$1/existing_records.hcl" && test -s "$1/zone-records.json" && grep -q "Exactly one DELEGATED zone" "$2"' _ "$T/snap1" "$T/out"
check "an empty duplicate-zone list is [] and never [\"\"] (QA-L-12)" bash -c 'grep -qx "duplicate_zone_ids      = \[\]" "$1/scalar-variables.txt" && ! grep -q "\[\"\"\]" "$1/scalar-variables.txt" "$2"' _ "$T/snap1" "$T/out"
export -f crs
check "no carriage return reaches any snapshot file although the mock answers in CRLF (QA-L-12)" bash -c 'test "$(cat "$1"/* | crs)" -eq 0' _ "$T/snap1"
check "no carriage return in the printed output either" bash -c 'test "$(crs < "$1")" -eq 0' _ "$T/out"
check "the zone comment is HCL-escaped: dollar-brace and percent-brace (QA-L-11)" grep -qxF 'existing_zone_comment   = "owner $${x} and %%{y} comment"' "$T/snap1/scalar-variables.txt"
check "the registered name servers carry no stray CR or quote" grep -qxF 'registered_name_servers = ["ns-1.example.org", "ns-2.example.org"]' "$T/snap1/scalar-variables.txt"
check "a TXT value loses its surrounding quotes and its dollar-brace is escaped (inventory)" grep -qF 'records = ["v=spf1 include:x $${y} -all"]' "$T/snap1/existing_records.hcl"
check "a multi-string TXT value becomes a single string with the doubled-quote join" grep -qF 'part-one\"\"part-two' "$T/snap1/existing_records.hcl"
check "the wildcard label is written as an asterisk" grep -qF 'name = "*.example.test"' "$T/snap1/existing_records.hcl"
check "apex NS and SOA are not in existing_records" bash -c '! grep -q "\"NS\"\|\"SOA\"" "$1"' _ "$T/snap1/existing_records.hcl"

# ---------------------------------------------------------------- case 2: a real duplicate zone
preflight "$T/snap2" MOCK_ZONES=zones-dup
check "a duplicate zone is listed as a quoted ID (QA-L-12)" grep -qxF 'duplicate_zone_ids      = ["Z2BBBBBBBBBBBBBBBBBB"]' "$T/snap2/scalar-variables.txt"
check "the delegated zone is still the one that matches the registered name servers" grep -qxF 'existing_zone_id        = "Z1AAAAAAAAAAAAAAAAAA"' "$T/snap2/scalar-variables.txt"
check "the duplicate is reported for owner review" grep -q "DUPLICATE zone Z2BBBBBBBBBBBBBBBBBB" "$T/out"

# ---------------------------------------------------------------- case 3: the SSM warning no longer says SecureStrings must be imported (NEW-12)
preflight "$T/snap3" MOCK_ZONES=zones-one "MOCK_SSM=/home-lab/authentik/secret-key	/home-lab/config/domain"
check "existing /home-lab parameters: the WARN explains that SecureStrings are owner-managed and only config/* is Terraform's (NEW-12)" bash -c 'grep -q "owner-managed" "$1" && grep -q "config/\*" "$1" && ! grep -qi "must be imported into terraform/edge before it can manage them" "$1"' _ "$T/out"
check "the parameter names are listed (names only)" grep -q "/home-lab/authentik/secret-key" "$T/out"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll aws-preflight checks passed\n'
