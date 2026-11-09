# Runbook: HCP Terraform and AWS bootstrap (milestone M1, step U9)

Audience: the owner. Everything here uses placeholders; real values stay in gitignored files or HCP workspace variables.

## What exists first (created by hand, documented exception)

HCP Terraform is Terraform's own control plane, so these objects are created in the HCP UI:

- an organization, and a project `home-lab`
- workspace `home-lab-bootstrap`: CLI-driven, **Local** execution (state only)
- workspace `home-lab`: CLI-driven, **Remote** execution, auto-apply off, destroy plans disabled, no VCS connection

Managing them with the `tfe` provider is Phase 2.

## Terraform version

The plan pinned Terraform 1.17.1. Both stacks use `required_version = "~> 1.16"` so a local 1.16.x also works; the language
features used exist since 1.7, and CI validates with 1.17.1. For the remote workspace, set **Settings > General > Terraform
Version** to 1.17.1 (or any 1.16+ release) so remote and local runs agree. Upgrade the local CLI when convenient.

## Steps

1. Log in and set the organization for your shell (never commit it):
   - `terraform login`
   - `export TF_CLOUD_ORGANIZATION=<your-hcp-organization>`
   - `aws sso login --profile henniefrancis`
2. Run the preflight and review it with the developer: `DOMAIN=<your-domain> scripts/aws-preflight.sh --snapshot`.
   It must end with `PREFLIGHT PASSED`. WARN lines are explained in [[adopt-existing-route53]] and below.
3. Create `terraform/bootstrap/terraform.tfvars` from the `.example` (gitignored):
   - `hcp_organization` is your organization name; `domain`, `home_lab_zone_id` (the delegated zone) and `owner_role_arn_pattern` (your SSO admin role) are required; `ca_cert_pem` once the offline CA exists (M2).
   - `oidc_provider_mode`: if the preflight warns that the `app.terraform.io` OIDC provider already exists (AWS allows one per
     account), use `existing` (read it, manage nothing; safest when another stack owns it) or `import` (adopt it; this stack
     then owns it and will retag it). Use `create` only if none exists.
4. Plan, review, apply (local execution, SSO profile):
   - `terraform -chdir=terraform/bootstrap init`
   - `terraform -chdir=terraform/bootstrap plan`
   - After the owner approves the plan: `terraform -chdir=terraform/bootstrap apply`
   - If the Go SDK reports `refresh cached SSO token failed` while the AWS CLI works, export short-lived credentials for the
     shell instead: `eval "$(aws configure export-credentials --profile henniefrancis --format env)"`, then add
     `-var aws_profile=` (empty) to plan and apply. Never print the exported variables.
5. Read the outputs: `terraform -chdir=terraform/bootstrap output`.
6. In HCP workspace `home-lab`, set the variables listed in `terraform/edge/workspace-variables.example.md` (environment variables
   `TFC_AWS_PROVIDER_AUTH=true`, `TFC_AWS_PLAN_ROLE_ARN`, `TFC_AWS_APPLY_ROLE_ARN`, `AWS_REGION=af-south-1`, then the Terraform
   variables). `budget_email` is **sensitive**.
7. Run the adoption plan and apply following [[adopt-existing-route53]]. Then follow [[secrets-ssm]] for the SSM verification.

## Role design (why two roles)

- `home-lab-hcp-plan` is read-only and trusted only for `run_phase:plan` of this exact org, project and workspace.
- `home-lab-hcp-apply` has scoped write and is trusted only for `run_phase:apply`. It cannot touch the OIDC provider or the
  `home-lab-hcp-*` roles, **cannot create or change ANY role, trust policy, inline policy or Roles Anywhere object** (no `iam:*` or `rolesanywhere:*` write, and an explicit deny; SEC-H1), cannot create IAM users or keys,
  may write SSM only under `/home-lab/config/` (the SecureStrings are owner-managed, ADR-013) and has no KMS permission, may change Route 53 records only in the home-lab hosted zone (SEC-M1), and is explicitly denied dangerous
  Route 53 Domains actions (delete, transfer, register, renew, contacts, auth code, transfer-lock disable, DS records, name server changes, disabling auto-renew). Route 53 Domains has no resource-level
  permissions, so its few allowed actions (`EnableDomainAutoRenew`, `EnableDomainTransferLock`, `UpdateTagsForDomain`) apply to every domain in the account; they are protective or metadata only.
- Changes to either run role are made here, from the laptop, never from the remote workspace.
- The identity the Pi uses (trust anchor, profiles, DNS-01 role, Pi-host role) and the SecureString key `alias/home-lab-ssm` are defined in this bootstrap stack too: they change only by your admin SSO apply
  (`identity.tf`, `kms.tf`; optional `audit.tf`). `sec-remediation-apply-order.md` has the migration order from the old layout.

## Audit logging (optional, N7, SEC-L1): prepared, NOT applied

Today the account has no CloudTrail trail and no IAM Access Analyzer (checked 2026-11-09), so SSM reads, KMS decrypts and Roles Anywhere sessions by the Pi are only in the 90 day
event history. `terraform/bootstrap/audit.tf` can add a trail; it is off by default (`enable_audit_logging = false`), nothing in the repo applies it, and an offline test
(`scripts/test-terraform-policies.sh`) proves that with the switch off nothing is created and that with it on the trail is multi-region with log file validation and the bucket is
private, SSE-S3 encrypted, versioned and refuses plain HTTP.

What it creates: one multi-region trail `home-lab-audit` (management events, global service events, log file validation), a private bucket
`home-lab-audit-<account>-af-south-1` (block public access, ownership enforced, versioning, SSE-S3, 365 day expiry, bucket policy limited to this trail and HTTPS), and an IAM Access
Analyzer of type ACCOUNT (external access findings).

Cost: CloudTrail delivers the first copy of management events in each Region free of charge; you pay only S3 storage and requests for the logs, a few MB per month for this
account (cents). The ACCOUNT-type (external access) analyzer is free. Skip it if the account already has an organisation trail (a second trail of management events would be billed).
Check the current CloudTrail pricing page before you switch it on.

Owner step (admin SSO, never from the remote workspace):

1. In the gitignored `terraform/bootstrap/terraform.tfvars` set `enable_audit_logging = true`.
2. `terraform -chdir=terraform/bootstrap plan` and read it: only additions (bucket and its settings, trail, analyzer), no change to roles or the key.
3. `terraform -chdir=terraform/bootstrap apply`, then `aws cloudtrail get-trail-status --name home-lab-audit --region af-south-1` shows `IsLogging: true`.
4. Later: an alarm on `DecryptException`/`AccessDenied` for `home-lab-pi-host` or on `kms:Decrypt` by any other principal (not part of this change).

The bucket has `prevent_destroy` (the logs outlive a mistake), so setting the variable back to false makes the plan fail on the bucket. To switch it off on purpose: `terraform state rm` the `aws_s3_bucket*.audit` resources first (the bucket and its logs stay, empty and delete it by hand if you want it gone), then set the variable to false and apply (the trail and analyzer are destroyed).

## Recovery

State for the bootstrap lives in HCP, so it can be re-run from any machine with `terraform login` and an SSO profile.
`prevent_destroy` is set on the roles (and on the OIDC provider when this stack manages it).

## Verification checklist

- [ ] `aws-preflight.sh` passes
- [ ] bootstrap plan shows only additions (no change to anything pre-existing)
- [ ] outputs set as workspace variables
- [ ] workspace has no VCS connection, auto-apply off, destroy plans disabled
