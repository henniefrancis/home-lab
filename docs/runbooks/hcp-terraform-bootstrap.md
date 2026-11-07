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
   - `hcp_organization` is your organization name.
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
  `home-lab-hcp-*` roles, cannot create IAM users or keys, may write SSM only under `/home-lab/`, and is explicitly denied dangerous
  Route 53 Domains actions (delete, transfer, register, renew, contacts, auth code, transfer-lock disable, DS records).
- Changes to either run role are made here, from the laptop, never from the remote workspace.
- Both roles read the AWS-managed `aws/ssm` key alias in af-south-1 (it exists once SSM has been used there; the preflight checks).

## Recovery

State for the bootstrap lives in HCP, so it can be re-run from any machine with `terraform login` and an SSO profile.
`prevent_destroy` is set on the roles (and on the OIDC provider when this stack manages it).

## Verification checklist

- [ ] `aws-preflight.sh` passes
- [ ] bootstrap plan shows only additions (no change to anything pre-existing)
- [ ] outputs set as workspace variables
- [ ] workspace has no VCS connection, auto-apply off, destroy plans disabled
