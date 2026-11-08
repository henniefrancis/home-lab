# Turns `aws route53 list-resource-record-sets` JSON into the HCL entries of the existing_records variable.
# Usage: jq -r --arg apex "<domain>." -f inventory.jq records.json
#
# - Apex NS and SOA are excluded (owned by the zone).
# - Names: trailing dot dropped, the octal escape for the wildcard label becomes a literal asterisk.
# - TXT and SPF values: Route 53 returns them wrapped in quotes, but aws_route53_record wants them WITHOUT the
#   surrounding quotes (the provider adds them). Each string loses one layer of quotes. A value made of several
#   strings (for example a long DKIM key returned as "a" "b") becomes a""b, the provider's documented form for
#   multi-string TXT. Escapes inside a string are kept as returned.
# - Map keys are the lowercased name and type with every run of other characters turned into one hyphen. They are the
#   for_each addresses in Terraform state, so the scheme must NEVER change: no trimming, no renaming (a change plans a
#   destroy and create of the record).
# - HCL-significant sequences (dollar-brace and percent-brace) are escaped.
def nm: (.Name | gsub("\\\\052"; "*") | sub("\\.$"; ""));
def esc: gsub("\\$\\{"; "$${") | gsub("%\\{"; "%%{");
def hcl: tojson | esc;
def unq:
  [scan("\"((?:[^\"\\\\]|\\\\.)*)\"") | .[0]] as $parts
  | if ($parts | length) == 0 then . else ($parts | join("\"\"")) end;
def val($t): if ($t == "TXT" or $t == "SPF") then unq else . end;
[ .ResourceRecordSets[]
  | select(((.Name == $apex) and (.Type == "NS" or .Type == "SOA")) | not) ]
| sort_by(.Name, .Type, (.SetIdentifier // ""))
# Two records that map to the same key would silently overwrite each other in HCL (QA-L-10): abort instead. The key scheme
# itself never changes, so existing state addresses stay valid.
| map(. + {_key: ((nm + "_" + .Type + (if .SetIdentifier then "_" + .SetIdentifier else "" end)) | ascii_downcase | gsub("[^a-z0-9]+"; "-"))})
| (group_by(._key) | map(select(length > 1) | .[0]._key)) as $dups
| if ($dups | length) > 0 then error("duplicate existing_records keys (records collide after normalisation): " + ($dups | join(", "))) else . end
| .[]
| .Type as $t
| ._key as $key
| "  " + ($key | hcl) + " = {\n"
  + "    name = " + (nm | hcl) + "\n"
  + "    type = " + (.Type | hcl) + "\n"
  + (if .TTL != null then "    ttl  = \(.TTL)\n" else "" end)
  + (if .ResourceRecords then "    records = [" + ([.ResourceRecords[].Value | val($t) | hcl] | join(", ")) + "]\n" else "" end)
  + (if .AliasTarget then "    alias = {\n      name                   = " + (.AliasTarget.DNSName | sub("\\.$"; "") | hcl)
      + "\n      zone_id                = " + (.AliasTarget.HostedZoneId | hcl)
      + "\n      evaluate_target_health = \(.AliasTarget.EvaluateTargetHealth)\n    }\n" else "" end)
  + (if .SetIdentifier then "    set_identifier = " + (.SetIdentifier | hcl) + "\n" else "" end)
  + "  }"
