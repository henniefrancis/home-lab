# Runbook: secrets in AWS SSM Parameter Store

Runtime secrets live in SSM Parameter Store (SecureString, Standard tier, region af-south-1) encrypted with the **customer-managed key `alias/home-lab-ssm`** (SEC-M2; defined in
`terraform/bootstrap/kms.tf`). Its key policy lets only the Pi host role decrypt (through SSM, for `parameter/home-lab/*` only); the owner's admin role and the HCP apply role can encrypt
but never decrypt; the account root keeps key management only. Other principals in the account that may call `ssm:GetParameter` on `*` cannot read these values.
Nothing secret is in git, Terraform state, CI or the repo checkout on the Pi.

## Model (ADR-013: script-managed, not Terraform-managed)

- **The six SecureStrings are owner-managed.** `config/secrets-manifest.tsv` (rows that do not start with `config/`) is the source of truth for the list:
  `authentik/secret-key`, `authentik/postgres-password`, `authentik/bootstrap-password`, `traefik/breakglass-htpasswd`, `tailscale/auth-key`, `homepage/authentik-token`.
  They are created, set and checked with `scripts/set-secret.sh` on the laptop (`--create`, set, `--unset`, `--check`). No Terraform resource or data source
  touches them. Why: the AWS provider reads a SecureString WithDecryption even for a write-only value, and the home-lab key policy correctly denies Decrypt to the HCP
  roles, so the remote plan failed on refresh (2026-11-08). Keeping Terraform in charge would have meant giving the HCP roles decrypt, which defeats SEC-M2.
  `terraform/edge` carries a `removed` block that only forgets the old resources in state; nothing is deleted in AWS.
- **Terraform** (`terraform/edge/ssm.tf`) owns only the `/home-lab/config/*` String parameters (domain, zone ID, Roles Anywhere ARNs).
- **The password manager** keeps the offline copy of every value.
- **The Pi** fetches the values at deploy time with the `home-lab-pi-host` identity, which can only read `/home-lab/*`.

## Setting a secret

```bash
aws sso login --profile henniefrancis
scripts/set-secret.sh --check                       # lists the six SecureStrings with key and version (never a value); fails if one is missing or not on alias/home-lab-ssm
scripts/set-secret.sh --create tailscale/auth-key   # only for a missing one: creates it with the UNSET placeholder (key alias/home-lab-ssm, Standard, tags Project and ManagedBy=set-secret.sh); refuses to overwrite
scripts/set-secret.sh authentik/secret-key          # set the value
```

- The prompt does not echo, asks twice, refuses empty values and values over 4096 characters, and strips a trailing carriage return. The value never appears in argv, shell history or a repo file.
  Every write passes `--key-id alias/home-lab-ssm` (override with `SSM_KEY_ALIAS`), so setting a value again also moves it to the current key.
  On Git Bash the request goes through a private temp file in a directory restricted to your Windows user, overwritten with random data and removed on every exit path; on Linux and WSL it goes through a
  pipe and no file exists, so **prefer WSL or Linux for secrets** (NTFS gives no secure-delete guarantee; accepted for the laptop, SEC-L7).
- The script prints the new version number only. Never read values back into a terminal or an agent.
- `scripts/set-secret.sh --unset tailscale/auth-key` writes the placeholder back (do this after Tailscale has joined).
- Names must be `<service>/<name>`; `config/*` is refused. `--create` accepts only names that are SecureString rows of the manifest: add the row first when you add a service.
- The Pi's `fetch-secrets.sh` still fails closed on a placeholder in a required parameter.

## Parameters

| Parameter | Purpose |
|-----------|---------|
| `/home-lab/authentik/secret-key` | Authentik secret key |
| `/home-lab/authentik/postgres-password` | Authentik PostgreSQL password |
| `/home-lab/authentik/bootstrap-password` | `akadmin` bootstrap password, first start only (optional; an empty file while UNSET; set it BEFORE the first M4 deploy, set it back to UNSET after the first login, see `m4-authentik.md`) |
| `/home-lab/traefik/breakglass-htpasswd` | break-glass basic-auth htpasswd line |
| `/home-lab/tailscale/auth-key` | one-off auth key, set back to UNSET after joining |
| `/home-lab/homepage/authentik-token` | optional Authentik API token for Homepage |

Adding a SecureString means a row in `config/secrets-manifest.tsv`, then `set-secret.sh --create <name>` and setting it. Adding a config value means a Terraform change in `ssm.tf` plus a `config/` row.

## IAM summary

- Apply role: SSM put, delete, get and tag actions on `parameter/home-lab/config/*` only. It has no KMS permission and an explicit deny on decrypt, on every `iam:*` and `rolesanywhere:*` write, and its Route 53
  write actions are limited to the home-lab hosted zone (`terraform/bootstrap/roles.tf`).
- Plan role: get and list-tags on `parameter/home-lab/config/*`, and `ssm:DescribeParameters`. No SecureString is readable by either HCP role and neither is a user of the key.
- Owner (admin SSO role matching `owner_role_arn_pattern`): may ENCRYPT through SSM with the key (key policy), never decrypt; that is what `set-secret.sh` needs.
- Pi host role `home-lab-pi-host`: read-only on `parameter/home-lab` and `parameter/home-lab/*`, decrypt through SSM only, on the home-lab key only, with an encryption-context condition
  (`kms:EncryptionContext:PARAMETER_ARN` must be under `parameter/home-lab/`). Both lab roles are defined in `terraform/bootstrap` (admin SSO), not in the HCP workspace.
- `GetParametersByPath` against the path root ARN is verified in M2 (first fetch on the Pi).

## Rotation and revocation

Rotate by running `set-secret.sh` for the parameter and redeploying. If a Pi is lost, follow `pi-recovery.md` (bump `pki_generation` in `terraform/bootstrap` and apply with admin SSO, reissue the certificates).

## Key migration and the move to owner-managed SecureStrings (2026-11-08)

The parameters were first encrypted under the AWS-managed `alias/aws/ssm` and Terraform-managed with write-only values. The owner re-set all six under `alias/home-lab-ssm`
(`set-secret.sh` passes `--key-id`), then the remote plan failed on refresh (the provider decrypts; the key denies the HCP roles). Resolution: Terraform forgets the six
(`removed` block, `destroy = false`) and the HCP roles lose their SecureString access. The order is in `sec-remediation-apply-order.md`.
