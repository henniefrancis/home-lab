# Workspace variables for the `home-lab` HCP workspace (placeholders only)

Set these in the HCP Terraform UI (workspace `home-lab`, Variables). Do not create `*.tfvars` files for this stack:
CLI-driven remote runs would upload them. Real values come from `scripts/aws-preflight.sh --snapshot` (local,
gitignored `adopt-snapshot/`) and from `terraform output` of the bootstrap stack.

| Name | Kind | Sensitive | Value |
|------|------|-----------|-------|
| `TFC_AWS_PROVIDER_AUTH` | env | no | `true` |
| `TFC_AWS_PLAN_ROLE_ARN` | env | no | bootstrap output `plan_role_arn` |
| `TFC_AWS_APPLY_ROLE_ARN` | env | no | bootstrap output `apply_role_arn` |
| `AWS_REGION` | env | no | `af-south-1` |
| `domain` | terraform | no | `example.com` |
| `existing_zone_id` | terraform | no | `Z0000000000000000000` |
| `existing_zone_comment` | terraform | no | the current zone comment, or an empty string |
| `registered_name_servers` | terraform, HCL | no | `["ns-1.awsdns-01.org", "ns-2.awsdns-02.net", "ns-3.awsdns-03.co.uk", "ns-4.awsdns-04.com"]` (exact order) |
| `domain_auto_renew` | terraform, HCL | no | `true` |
| `domain_transfer_lock` | terraform, HCL | no | `null` when the TLD has no lock, else `true` or `false` |
| `existing_records` | terraform, HCL | no | paste `adopt-snapshot/existing_records.hcl` contents after the `=` (see below) |
| `duplicate_zone_ids` | terraform, HCL | no | `[]` |
| `adopt_planned_records` | terraform, HCL | no | `{}` (set a flag true only for a collision, see the runbook) |
| `create_planned_records` | terraform, HCL | no | `false` during adoption, `true` in the follow-up apply |
| `create_ssm_parameters` | terraform, HCL | no | `false` during adoption, `true` in a follow-up apply (then run the verification in `docs/runbooks/secrets-ssm.md`) |
| `pki_generation` | terraform | no | `gen-1` (default; bump to revoke a lost Pi) |
| `pi_tailnet_ipv4` | terraform | no | omit until M2, then `100.x.y.z` |
| `ca_cert_pem` | terraform | no | omit until M2, then the public CA certificate PEM |
| `budget_usd` | terraform, HCL | no | `5` |
| `budget_email` | terraform | **yes** | omit until the budget apply, then the owner's own address |

`existing_records` shape (one entry per record; values exactly as found):

```hcl
{
  "example-key" = {
    name    = "host.example.com"
    type    = "CNAME"
    ttl     = 3600
    records = ["target.example.net"]
  }
}
```

Alias records use `alias = { name, zone_id, evaluate_target_health }` instead of `ttl` and `records`.
