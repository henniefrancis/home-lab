# Runbook: secrets in AWS SSM Parameter Store

Runtime secrets live in SSM Parameter Store (SecureString, Standard tier, region af-south-1) encrypted with the **customer-managed key `alias/home-lab-ssm`** (SEC-M2; defined in
`terraform/bootstrap/kms.tf`). Its key policy lets only the Pi host role decrypt (through SSM, for `parameter/home-lab/*` only); the owner's admin role and the HCP apply role can encrypt
but never decrypt; the account root keeps key management only. Other principals in the account that may call `ssm:GetParameter` on `*` cannot read these values.
Nothing secret is in git, Terraform state, CI or the repo checkout on the Pi.

## Model

- **Terraform** (`terraform/edge/ssm.tf`) creates each SecureString with the write-only argument `value_wo` set to the placeholder
  `UNSET-set-via-set-secret`, `value_wo_version = 1` and `key_id = "alias/home-lab-ssm"`. Write-only values are never stored in state. The `/home-lab/config/*`
  String parameters (domain, zone ID, Roles Anywhere ARNs) are Terraform-owned.
- **The owner** sets real values with `scripts/set-secret.sh` on the laptop. This is the one documented exception to the
  Terraform-only rule: the resource is Terraform-managed, only the value is set out of band. The password manager keeps the offline copy.
- **The Pi** (milestone M2) fetches the values at deploy time with the `home-lab-pi-host` identity, which can only read `/home-lab/*`.

**Never bump `value_wo_version`.** A new version re-sends the placeholder and overwrites the real value. CI fails if it is not 1.

## Setting a secret

```bash
aws sso login --profile henniefrancis
scripts/set-secret.sh authentik/secret-key
```

- The prompt does not echo, asks twice, refuses empty values and values over 4096 characters, and strips a trailing carriage return. The value never appears in argv, shell history or a repo file.
  Every write passes `--key-id alias/home-lab-ssm` (override with `SSM_KEY_ALIAS`), so setting a value again also moves it to the current key.
  On Git Bash the request goes through a private temp file in a directory restricted to your Windows user, overwritten with random data and removed on every exit path; on Linux and WSL it goes through a
  pipe and no file exists, so **prefer WSL or Linux for secrets** (NTFS gives no secure-delete guarantee; accepted for the laptop, SEC-L7).
- The script prints the new version number only. Never read values back into a terminal or an agent.
- `scripts/set-secret.sh --unset tailscale/auth-key` writes the placeholder back (do this after Tailscale has joined).
- Names must be `<service>/<name>`; `config/*` is refused.

## Required one-off verification (before any real value is set)

The provider must not copy the decrypted value into state. Verify once, after the first apply of `ssm.tf`:

1. Apply `terraform/edge` so the parameters exist with the placeholder.
2. Set a **dummy** value on one parameter: `scripts/set-secret.sh tailscale/auth-key` (type something like `dummy-value`).
3. Run a remote refresh-only plan: `terraform -chdir=terraform/edge plan -refresh-only`.
   If it fails with an access error mentioning `kms:Decrypt`, STOP and tell the developer: the plan and apply roles are deliberately denied decrypt on the home-lab key (key policy and IAM),
   which proved unnecessary for the refresh on 2026-11-07. Do not grant it; investigate (a provider change that reads with decryption would put values at risk).
4. Inspect the state **without printing values**, counting matches only. Download the state from the HCP UI into a private folder, then:
   - `jq '[.resources[] | select(.type=="aws_ssm_parameter" and .name=="secret") | .instances[].attributes | select((.value // "") != "")] | length' state.json` must print `0`
   - `grep -c 'dummy-value' state.json` must print `0`
   - `has_value_wo` should be `true` for each secret parameter
   Delete the downloaded state afterwards.
5. Record the result in the table below.

If the provider **does** put the value in state, stop and switch to the fallback: `set-secret.sh --create` creates the SecureStrings,
Terraform manages only the IAM, KMS and String parameters, and the broader exception is documented here.

Afterwards put the placeholder back with `--unset`, or overwrite the dummy with the real value.

| Date | Provider version | Value in state | Notes |
|------|------------------|----------------|-------|
| 2026-11-07 | hashicorp/aws 6.72.0, Terraform 1.17.1 (HCP remote) | No | Dummy set on `tailscale/auth-key`, refresh-only apply, current state downloaded: dummy 0 hits, placeholder 0 hits, `value`/`insecure_value` empty and `has_value_wo = true` on all 6 SecureStrings. Plan-phase refresh worked without `kms:Decrypt`, so the plan role stays without it. Placeholder restored; next plan "No changes". |

## Parameters

| Parameter | Purpose |
|-----------|---------|
| `/home-lab/authentik/secret-key` | Authentik secret key |
| `/home-lab/authentik/postgres-password` | Authentik PostgreSQL password |
| `/home-lab/authentik/bootstrap-password` | `akadmin` bootstrap password, first start only (optional; an empty file while UNSET; set it BEFORE the first M4 deploy, set it back to UNSET after the first login, see `m4-authentik.md`) |
| `/home-lab/traefik/breakglass-htpasswd` | break-glass basic-auth htpasswd line |
| `/home-lab/tailscale/auth-key` | one-off auth key, set back to UNSET after joining |
| `/home-lab/homepage/authentik-token` | optional Authentik API token for Homepage |

Adding a parameter means adding it to `local.secure_params` in `ssm.tf`, a row in `config/secrets-manifest.tsv`, then running `set-secret.sh`.

## IAM summary

- Apply role: `ssm` put, delete, get and tag actions on `parameter/home-lab/*` only, plus KMS encrypt and generate-data-key through SSM on the home-lab key only. It has an explicit deny on decrypt, on
  every `iam:*` and `rolesanywhere:*` write, and its Route 53 write actions are limited to the home-lab hosted zone (`terraform/bootstrap/roles.tf`).
- Plan role: get and list-tags on `parameter/home-lab/*`, and `ssm:DescribeParameters`.
- Pi host role `home-lab-pi-host`: read-only on `parameter/home-lab` and `parameter/home-lab/*`, decrypt through SSM only, on the home-lab key only, with an encryption-context condition
  (`kms:EncryptionContext:PARAMETER_ARN` must be under `parameter/home-lab/`). Both roles are defined in `terraform/bootstrap` (admin SSO), not in the HCP workspace. The Traefik role has no SSM access.
- `GetParametersByPath` against the path root ARN is verified in M2 (first fetch on the Pi).

## Rotation and revocation

Rotate by running `set-secret.sh` for the parameter and redeploying. If a Pi is lost, follow `pi-recovery.md` (bump `pki_generation` in `terraform/bootstrap` and apply with admin SSO, reissue the certificates).

## Key migration (one-off, 2026-11-08)

The parameters were first encrypted under the AWS-managed `alias/aws/ssm`. A write-only value cannot be re-encrypted by Terraform, so the migration is: apply `terraform/bootstrap` (creates the key,
with `allow_legacy_ssm_key = true` for the window), re-set every SecureString with `set-secret.sh` (it now passes `--key-id`), verify with `aws ssm describe-parameters` that every SecureString shows
`alias/home-lab-ssm`, apply `terraform/edge` (expect NO change on the parameters), then remove the legacy flag. The exact commands are in `sec-remediation-apply-order.md`.
