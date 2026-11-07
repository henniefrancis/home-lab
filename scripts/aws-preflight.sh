#!/usr/bin/env bash
# aws-preflight.sh - read-only AWS + HCP Terraform gate that must pass before ANY apply (plan section 6.9).
#
# Usage:
#   DOMAIN=<your-domain> TF_CLOUD_ORGANIZATION=<hcp-org> scripts/aws-preflight.sh [--snapshot]
#   scripts/aws-preflight.sh <your-domain> [--snapshot]
#
# Environment (all optional except DOMAIN):
#   DOMAIN                   the registered domain
#   AWS_PROFILE_NAME         AWS CLI profile (default: henniefrancis)
#   TF_CLOUD_ORGANIZATION    HCP Terraform organization (never hard-coded in the repo)
#   SNAPSHOT_DIR             where --snapshot writes (default: adopt-snapshot/, which is gitignored)
#
# Read-only: it calls only Get/List/Describe/Simulate APIs and `terraform init`. It prints no secrets.
# It prints the domain and account locally, so never paste its output into a public place.
# Exit status: 0 = no FAIL, 1 = at least one FAIL.
set -uo pipefail

PROFILE="${AWS_PROFILE_NAME:-henniefrancis}"
DOMAIN="${DOMAIN:-}"
SNAPSHOT=0
for arg in "$@"; do
  case "$arg" in
    --snapshot) SNAPSHOT=1 ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) DOMAIN="$arg" ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$REPO_ROOT/adopt-snapshot}"
FAILS=0
WARNS=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf '      %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

# aws.exe on Git Bash/Windows emits CRLF; strip every CR so values never carry a stray CR (pipefail keeps aws failures visible).
# jq.exe on Windows can do the same, so it is wrapped too.
jq() { command jq "$@" | tr -d '\r'; }
# MSYS_NO_PATHCONV stops Git Bash rewriting arguments such as /home-lab into a Windows path (scoped to aws only).
aws_() { MSYS_NO_PATHCONV=1 aws --profile "$PROFILE" --no-cli-pager "$@" | tr -d '\r'; }
# HCL list of duplicate zone IDs; an empty list prints [] (never [""]).
dup_ids_hcl() {
  local out="" id
  for id in ${DUP_IDS[@]+"${DUP_IDS[@]}"}; do out="${out:+$out, }\"$id\""; done
  printf '[%s]' "$out"
}
norm_ns() { tr '[:upper:]' '[:lower:]' | sed 's/\.$//' | sort; }

# Public DNS lookups: dig when present, else DNS-over-HTTPS (curl + jq). Prints one answer per line.
dns_query() {
  local name="$1" type="$2"
  if command -v dig > /dev/null 2>&1; then
    dig +short "$type" "$name" @1.1.1.1
  elif command -v curl > /dev/null 2>&1; then
    curl -fsS --max-time 15 -H 'accept: application/dns-json' \
      "https://cloudflare-dns.com/dns-query?name=${name}&type=${type}" 2> /dev/null |
      jq -r '.Answer[]? | .data'
  else
    return 1
  fi
}

# --------------------------------------------------------------------------------------------------
section "1. Tooling"
if [ -z "$DOMAIN" ]; then
  fail "DOMAIN is not set (export DOMAIN=<your-domain> or pass it as an argument)"
  echo "Preflight cannot continue."
  exit 1
fi
if ! [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
  fail "DOMAIN does not look like a lowercase domain name"
  exit 1
fi
for tool in aws jq terraform; do
  if command -v "$tool" > /dev/null 2>&1; then pass "$tool found"; else fail "$tool not found on PATH"; fi
done
if command -v aws > /dev/null 2>&1; then
  v="$(aws --version 2>&1 | awk '{print $1}')"
  case "$v" in aws-cli/2.*) pass "AWS CLI v2 ($v)" ;; *) fail "AWS CLI v2 required, found $v" ;; esac
fi
if command -v terraform > /dev/null 2>&1; then
  tfv="$(terraform version -json 2> /dev/null | jq -r .terraform_version 2> /dev/null || true)"
  if [ -z "$tfv" ]; then
    tfv="$(terraform version | head -1 | sed 's/^Terraform v//')"
  fi
  major="${tfv%%.*}"
  rest="${tfv#*.}"
  minor="${rest%%.*}"
  if [ "$major" = 1 ] && [ "${minor:-0}" -ge 16 ]; then
    pass "Terraform $tfv (>= 1.16 required; the plan pinned 1.17.x, see docs/runbooks/hcp-terraform-bootstrap.md)"
  else
    fail "Terraform >= 1.16 required, found $tfv"
  fi
fi
[ "$FAILS" -gt 0 ] && { echo "Fix tooling first."; exit 1; }

# --------------------------------------------------------------------------------------------------
section "2. HCP Terraform"
if [ -n "${TF_CLOUD_ORGANIZATION:-}" ]; then
  pass "TF_CLOUD_ORGANIZATION is set"
else
  fail "TF_CLOUD_ORGANIZATION is not set (export it; it is deliberately not stored in the repo)"
fi
tf_creds="${TF_CLI_CONFIG_FILE:-}"
if [ -f "${APPDATA:-/nonexistent}/terraform.d/credentials.tfrc.json" ] ||
  [ -f "$HOME/.terraform.d/credentials.tfrc.json" ] || [ -n "${TF_TOKEN_app_terraform_io:-}" ] ||
  { [ -n "$tf_creds" ] && [ -f "$tf_creds" ]; }; then
  pass "HCP Terraform credentials present (presence only, contents never read)"
else
  fail "No HCP Terraform credentials found; run: terraform login"
fi
if [ -d "$REPO_ROOT/terraform/bootstrap" ] && [ -n "${TF_CLOUD_ORGANIZATION:-}" ]; then
  if terraform -chdir="$REPO_ROOT/terraform/bootstrap" init -input=false -no-color > /dev/null 2>&1; then
    pass "terraform -chdir=terraform/bootstrap init succeeded"
  else
    fail "terraform -chdir=terraform/bootstrap init failed (run it by hand to see why)"
  fi
fi

# --------------------------------------------------------------------------------------------------
section "3. Identity"
if ident="$(aws_ sts get-caller-identity --output json 2> /dev/null)"; then
  ACCOUNT="$(jq -r .Account <<< "$ident")"
  CALLER_ARN="$(jq -r .Arn <<< "$ident")"
  pass "Authenticated as profile '$PROFILE' in account $ACCOUNT"
else
  fail "Cannot authenticate (expired SSO session?). Run: aws sso login --profile $PROFILE"
  echo "Preflight cannot continue without AWS credentials."
  exit 1
fi

# --------------------------------------------------------------------------------------------------
section "4. Region af-south-1"
opt="$(aws_ account get-region-opt-status --region-name af-south-1 --query RegionOptStatus --output text 2> /dev/null || true)"
case "$opt" in
  ENABLED | ENABLED_BY_DEFAULT) pass "af-south-1 is enabled ($opt)" ;;
  "") warn "Could not read af-south-1 opt-in status (missing account:GetRegionOptStatus?)" ;;
  *) fail "af-south-1 status is '$opt'. Enable it (R24) or choose a fallback region for Roles Anywhere (eu-west-1)." ;;
esac

# --------------------------------------------------------------------------------------------------
section "5. Roles Anywhere (also detects an SCP block)"
if ta="$(aws_ rolesanywhere list-trust-anchors --region af-south-1 --output json 2> /dev/null)"; then
  pass "rolesanywhere list-trust-anchors works in af-south-1 ($(jq '.trustAnchors | length' <<< "$ta") existing trust anchors)"
else
  fail "rolesanywhere list-trust-anchors failed in af-south-1 (region disabled or blocked by an SCP?)"
fi

# --------------------------------------------------------------------------------------------------
section "6. Registered domain (Route 53 Domains, us-east-1)"
REG_NS=""
AUTORENEW=""
TLOCK=""
if reg="$(aws_ route53domains get-domain-detail --region us-east-1 --domain-name "$DOMAIN" --output json 2> /dev/null)"; then
  pass "Domain is registered in this account"
  REG_NS="$(jq -r '.Nameservers[].Name' <<< "$reg")"
  AUTORENEW="$(jq -r .AutoRenew <<< "$reg")"
  TLOCK="$(jq -r .TransferLock <<< "$reg")"
  info "Registered nameservers, in order:"
  while IFS= read -r n; do info "  $n"; done <<< "$REG_NS"
  info "AutoRenew=$AUTORENEW TransferLock=$TLOCK AdminPrivacy=$(jq -r .AdminPrivacy <<< "$reg") RegistrantPrivacy=$(jq -r .RegistrantPrivacy <<< "$reg") TechPrivacy=$(jq -r .TechPrivacy <<< "$reg")"
  info "Expiry=$(jq -r .ExpirationDate <<< "$reg")"
  dnssec_n="$(jq -r '(.DnssecKeys // []) | length' <<< "$reg")"
  if [ "$dnssec_n" = 0 ]; then
    pass "DnssecKeys count = 0 (DNSSEC off, as expected)"
  else
    fail "DnssecKeys count = $dnssec_n (plan assumes DNSSEC is off; review before adopting)"
  fi
else
  fail "get-domain-detail failed: the domain is not registered in this account (or no permission)"
fi

# --------------------------------------------------------------------------------------------------
section "7. Hosted zones (adoption inventory)"
DELEGATED_ID=""
DUP_IDS=()
if zones="$(aws_ route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --output json 2> /dev/null)"; then
  mapfile -t ZONE_IDS < <(jq -r --arg d "${DOMAIN}." '.HostedZones[] | select(.Name == $d and (.Config.PrivateZone | not)) | .Id' <<< "$zones" | sed 's#/hostedzone/##')
  info "Public zones named exactly '$DOMAIN': ${#ZONE_IDS[@]}"
  matches=0
  for zid in "${ZONE_IDS[@]}"; do
    z="$(aws_ route53 get-hosted-zone --id "$zid" --output json)"
    zns="$(jq -r '.DelegationSet.NameServers[]' <<< "$z" | norm_ns)"
    rns="$(printf '%s\n' "$REG_NS" | norm_ns)"
    comment="$(jq -r '.HostedZone.Config.Comment // ""' <<< "$z")"
    count="$(jq -r .HostedZone.ResourceRecordSetCount <<< "$z")"
    if [ -n "$REG_NS" ] && [ "$zns" = "$rns" ]; then
      status="DELEGATED"
      matches=$((matches + 1))
      DELEGATED_ID="$zid"
    else
      status="DUPLICATE"
      DUP_IDS+=("$zid")
    fi
    info "$status zone $zid records=$count comment='$comment'"
    info "  NS: $(jq -r '.DelegationSet.NameServers | join(" ")' <<< "$z")"
    info "  tags: $(aws_ route53 list-tags-for-resource --resource-type hostedzone --resource-id "$zid" --query 'ResourceTagSet.Tags' --output json 2> /dev/null | jq -c . 2> /dev/null || echo unreadable)"
    if [ "$status" = DUPLICATE ]; then
      nonns="$(aws_ route53 list-resource-record-sets --hosted-zone-id "$zid" --output json | jq '[.ResourceRecordSets[] | select(.Type != "NS" and .Type != "SOA")] | length')"
      warn "DUPLICATE zone $zid has $nonns non-NS/SOA records; owner review needed before removal (add to duplicate_zone_ids)"
    fi
  done
  if [ "$matches" = 1 ]; then
    pass "Exactly one DELEGATED zone: $DELEGATED_ID"
  elif [ "$matches" = 0 ]; then
    fail "No zone's NS set equals the registered NS set (wrong zone, or delegation drift)"
  else
    fail "$matches zones match the registered NS set; expected exactly one"
  fi
else
  fail "list-hosted-zones-by-name failed"
fi

INVENTORY_HCL=""
if [ -n "$DELEGATED_ID" ]; then
  rrs="$(aws_ route53 list-resource-record-sets --hosted-zone-id "$DELEGATED_ID" --output json)"
  zinfo="$(aws_ route53 get-hosted-zone --id "$DELEGATED_ID" --output json)"
  apex="${DOMAIN}."

  # Records to manage = everything except apex NS and SOA. Names are normalised: trailing dot dropped,
  # \052 -> '*'. HCL-significant sequences in values are escaped.
  inv="$(jq -r --arg apex "$apex" -f "$(dirname "${BASH_SOURCE[0]}")/inventory.jq" <<< "$rrs")"
  INVENTORY_HCL="existing_records = {
$inv
}"

  echo
  info "Records in the delegated zone (apex NS/SOA excluded), NAME TYPE:"
  jq -r --arg apex "$apex" '.ResourceRecordSets[] | select(((.Name == $apex) and (.Type == "NS" or .Type == "SOA")) | not) | "  \(.Name | gsub("\\\\052"; "*")) \(.Type)\(if .AliasTarget then " (alias)" else "" end)\(if .SetIdentifier then " (set-id)" else "" end)"' <<< "$rrs"
  total="$(jq '[.ResourceRecordSets[] | select(((.Name == $apex) and (.Type == "NS" or .Type == "SOA")) | not)] | length' --arg apex "$apex" <<< "$rrs")"
  info "Total adoptable records: $total"

  # Routing policies other than simple need extra attributes that existing_records does not model.
  complex="$(jq -r '[.ResourceRecordSets[] | select(.Weight != null or .Region != null or .Failover != null or .GeoLocation != null or .MultiValueAnswer != null or .HealthCheckId != null or .GeoProximityLocation != null or .CidrRoutingConfig != null)] | length' <<< "$rrs")"
  if [ "$complex" != 0 ]; then
    warn "$complex record(s) use a routing policy or health check that existing_records cannot model; extend the schema before adopting"
  fi

  # Collisions with planned records.
  apex_nodot="$DOMAIN"
  coll="$(jq -r --arg apex "$apex" --arg d "$apex_nodot" '
    def nm: (.Name | gsub("\\\\052"; "*"));
    .ResourceRecordSets[]
    | select( (nm == ("*." + $apex) and .Type == "A")
              or (nm == ("www." + $apex))
              or (nm == $apex and .Type == "CAA") )
    | "  COLLISION: \(nm) \(.Type)"' <<< "$rrs")"
  if [ -n "$coll" ]; then
    warn "Records collide with planned lab records (import at the planned address, see runbook AD3):"
    printf '%s\n' "$coll"
  else
    pass "No collisions with planned records (* A, www, apex CAA)"
  fi

  # Leftover ACME challenges.
  acme="$(jq -r '.ResourceRecordSets[] | select(.Name | test("^_acme-challenge\\.")) | "  \(.Name) \(.Type)"' <<< "$rrs")"
  if [ -n "$acme" ]; then
    warn "Leftover _acme-challenge records (never managed by Terraform; decide DROP):"
    printf '%s\n' "$acme"
  else
    pass "No leftover _acme-challenge records"
  fi

  # Apex or www address records pointing at private / CGNAT space.
  badaddr="$(jq -r --arg apex "$apex" '
    def nm: (.Name | gsub("\\\\052"; "*"));
    def priv: test("^(10\\.|127\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)");
    .ResourceRecordSets[]
    | select((nm == $apex or nm == ("www." + $apex)) and (.Type == "A" or .Type == "AAAA" or .Type == "CNAME" or .AliasTarget != null))
    | select(.AliasTarget != null or ([.ResourceRecords[]?.Value | priv] | any))
    | "  \(nm) \(.Type)"' <<< "$rrs")"
  if [ -n "$badaddr" ]; then
    warn "Apex or www address record present (apex/www are reserved for the future public website; classify KEEP/REPLACE/DROP):"
    printf '%s\n' "$badaddr"
  else
    pass "No apex/www address records pointing at private or CGNAT space"
  fi

  # Suggested values for the workspace variables (no secrets; account-identifying, so keep local).
  echo
  info "Suggested workspace variable values (LOCAL ONLY):"
  info "  existing_zone_id        = \"$DELEGATED_ID\""
  info "  existing_zone_comment   = $(jq -r '.HostedZone.Config.Comment // ""' <<< "$zinfo" | jq -R .)"
  if [ -n "$REG_NS" ]; then
    info "  registered_name_servers = [$(printf '%s\n' "$REG_NS" | jq -R . | paste -sd, - | sed 's/,/, /g')]"
  fi
  if [ -n "${AUTORENEW:-}" ]; then
    info "  domain_auto_renew       = ${AUTORENEW:-}"
    info "  domain_transfer_lock    = ${TLOCK:-}"
  fi
  info "  duplicate_zone_ids      = $(dup_ids_hcl)"

  if [ "$SNAPSHOT" = 1 ]; then
    mkdir -p "$SNAPSHOT_DIR"
    chmod 700 "$SNAPSHOT_DIR" 2> /dev/null || true
    printf '%s\n' "$rrs" > "$SNAPSHOT_DIR/zone-records.json"
    printf '%s\n' "$INVENTORY_HCL" > "$SNAPSHOT_DIR/existing_records.hcl"
    {
      echo "existing_zone_id        = \"$DELEGATED_ID\""
      echo "existing_zone_comment   = $(jq -r '.HostedZone.Config.Comment // ""' <<< "$zinfo" | jq -R .)"
      echo "registered_name_servers = [$(printf '%s\n' "$REG_NS" | jq -R . | paste -sd, - | sed 's/,/, /g')]"
      echo "domain_auto_renew       = $(printf '%s' "${AUTORENEW:-}")"
      echo "domain_transfer_lock    = $(printf '%s' "${TLOCK:-}")"
      echo "duplicate_zone_ids      = $(dup_ids_hcl)"
    } > "$SNAPSHOT_DIR/scalar-variables.txt"
    pass "Snapshot written to $SNAPSHOT_DIR (gitignored; never commit)"
  fi
fi

# --------------------------------------------------------------------------------------------------
section "8. DNS and DNSSEC sanity (public resolvers)"
if pub_ns="$(dns_query "$DOMAIN" NS)" && [ -n "$pub_ns" ]; then
  if [ "$(printf '%s\n' "$pub_ns" | norm_ns)" = "$(printf '%s\n' "$REG_NS" | norm_ns)" ]; then
    pass "Public NS for the domain equal the registered NS"
  else
    fail "Public NS differ from the registered NS (delegation not yet propagated, or drift)"
  fi
else
  warn "Could not query public NS (no dig and no DoH access)"
fi
if ds="$(dns_query "$DOMAIN" DS)"; then
  if [ -z "$ds" ]; then pass "No DS record published at the parent (DNSSEC off)"; else fail "DS record present at the parent: DNSSEC is on, which Phase 1 does not manage"; fi
else
  warn "Could not query DS record"
fi

# --------------------------------------------------------------------------------------------------
section "9. Existing IAM objects that would need importing"
oidc="$(aws_ iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2> /dev/null | tr '\t' '\n' | grep -c 'oidc-provider/app.terraform.io$' || true)"
if [ "${oidc:-0}" -gt 0 ]; then warn "OIDC provider app.terraform.io already exists (set oidc_provider_mode in bootstrap: existing = manage nothing, import = adopt it)"; else pass "No existing OIDC provider app.terraform.io"; fi
for role in home-lab-hcp-plan home-lab-hcp-apply home-lab-traefik-dns01 home-lab-pi-host; do
  if aws_ iam get-role --role-name "$role" > /dev/null 2>&1; then
    case "$role" in
      home-lab-hcp-plan | home-lab-hcp-apply) warn "IAM role $role already exists (expected after the bootstrap apply)" ;;
      *) warn "IAM role $role already exists (must be imported into terraform/edge)" ;;
    esac
  else
    pass "IAM role $role does not exist yet"
  fi
done

# --------------------------------------------------------------------------------------------------
section "9b. SSM Parameter Store (af-south-1)"
if ssm_out="$(aws_ ssm describe-parameters --region af-south-1   --parameter-filters "Key=Path,Option=Recursive,Values=/home-lab" --query 'Parameters[].Name' --output text 2> /dev/null)"; then
  if [ -z "$ssm_out" ]; then
    pass "No existing /home-lab/* parameters (names only are ever listed, never values)"
  else
    warn "Existing /home-lab/* parameters (must be imported into terraform/edge before it can manage them):"
    printf '%s
' "$ssm_out" | tr '	' '
' | sed 's/^/        /'
  fi
else
  warn "Could not list SSM parameters in af-south-1 (missing ssm:DescribeParameters?)"
fi
if aws_ kms describe-key --key-id alias/aws/ssm --region af-south-1 > /dev/null 2>&1; then
  pass "KMS alias alias/aws/ssm exists in af-south-1"
else
  warn "KMS alias alias/aws/ssm not found in af-south-1 (created on first SSM SecureString use; Terraform needs it for the IAM policies)"
fi

# --------------------------------------------------------------------------------------------------
section "10. Permissions and Organizations (WARN-only)"
role_name="$(printf '%s' "$CALLER_ARN" | sed -n 's#^arn:aws:sts::[0-9]*:assumed-role/\([^/]*\)/.*#\1#p')"
if [ -n "$role_name" ] && role_arn="$(aws_ iam get-role --role-name "$role_name" --query Role.Arn --output text 2> /dev/null)"; then
  actions=(iam:CreateOpenIDConnectProvider iam:CreateRole iam:PutRolePolicy iam:PassRole
    route53:ChangeResourceRecordSets route53:CreateHostedZone route53domains:GetDomainDetail
    route53domains:UpdateDomainNameservers rolesanywhere:CreateTrustAnchor rolesanywhere:CreateProfile
    budgets:ModifyBudget ssm:PutParameter ssm:DescribeParameters kms:Encrypt)
  denied="$(aws_ iam simulate-principal-policy --policy-source-arn "$role_arn" --action-names "${actions[@]}" \
    --query "EvaluationResults[?EvalDecision!='allowed'].EvalActionName" --output text 2> /dev/null || echo SIMFAIL)"
  if [ "$denied" = SIMFAIL ]; then
    warn "simulate-principal-policy failed (no iam:SimulatePrincipalPolicy?)"
  elif [ -z "$denied" ]; then
    pass "Simulation: all ${#actions[@]} bootstrap actions allowed for $role_name (identity policies only; SCPs not modelled)"
  else
    warn "Simulation: not allowed -> $denied"
  fi
else
  warn "Could not resolve the caller's IAM role for simulation"
fi
if org="$(aws_ organizations describe-organization --output json 2> /dev/null)"; then
  info "Organizations: member of an organization (feature set $(jq -r .Organization.FeatureSet <<< "$org")); SCPs may apply"
else
  info "Organizations: not readable from this account (standalone account, or no permission)"
fi

# --------------------------------------------------------------------------------------------------
section "Summary"
echo "FAIL=$FAILS WARN=$WARNS"
if [ "$FAILS" -gt 0 ]; then
  echo "PREFLIGHT FAILED: do not apply anything."
  exit 1
fi
echo "PREFLIGHT PASSED (review WARN lines with the owner)."
