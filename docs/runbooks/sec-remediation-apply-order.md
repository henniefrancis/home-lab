# Runbook: security and QA remediation, owner apply order (2026-11-08)

Audience: the owner. Everything here is a placeholder or a command shape; real values stay in the gitignored `terraform/bootstrap/terraform.tfvars`, the HCP workspace
variables and the password manager. Nothing in this runbook has been run against AWS, HCP or the Pi: the code was validated offline (see the findings resolution note).

What changed, in one paragraph: the Pi's AWS identity (Roles Anywhere trust anchor, two profiles, the DNS-01 role and the Pi-host role) moved from `terraform/edge`
(applied by the HCP apply role) to `terraform/bootstrap` (applied by you, admin SSO). The HCP apply role lost every `iam:*` and `rolesanywhere:*` write permission, is
scoped to the home-lab hosted zone, and can no longer decrypt secrets. SecureStrings move to a customer-managed key. The Docker socket proxy is gone, deploys verify a
signature, and the checkout is root-owned.

Why "remove the permission" and not a permissions boundary: IAM conditions cannot constrain the contents of a trust policy, so a boundary on `iam:UpdateAssumeRolePolicy`
or `iam:CreateRole` cannot make role edits safe, and a boundary plus a deny list is more moving parts than simply moving the roles to the stack you apply yourself.
The two roles change rarely; an admin SSO apply is the right place for them.

## Order at a glance

| # | Who | What | Reversible? |
|---|-----|------|-------------|
| 0 | Laptop | Pull the commits, run the offline self-tests, set up commit signing (section 1) | yes |
| 1 | Owner | `terraform/bootstrap` apply with the migration flags (section 2): imports the live identity, creates the KMS key, narrows the apply role | yes (the old edge layout still has the objects in its state until step 3) |
| 2 | Owner | Re-set every secret with `set-secret.sh` so it is encrypted under the new key (section 3) | yes |
| 3 | Owner or lead | HCP workspace `home-lab`: new variables, then plan and apply `terraform/edge` (section 4) | yes |
| 4 | Owner | Close the migration window in bootstrap (section 5) | yes |
| 5 | Pi | Bootstrap, signing key, ownership, deploy (section 6) | yes |
| 6 | Owner | GitHub, Tailscale and Authentik settings (section 7) | yes |

Do the steps in this order. Steps 1 to 4 can be done without touching the Pi, but the Pi cannot fetch secrets between step 2 and the end of step 3 only if you skipped
`allow_legacy_ssm_key` (below), so do not skip it.

## 1. Laptop: offline checks and signing

```bash
git pull
bash scripts/test-ops-scripts.sh && bash scripts/test-set-secret.sh && bash scripts/test-inventory.sh && bash scripts/test-traefik-config.sh
```

Then create the commit-signing key and tell git about it (`m2-pi-setup.md` section 3.1). Every commit you push from now on must be signed, or the Pi will refuse to deploy it.

## 2. `terraform/bootstrap`: migration apply (admin SSO, local)

Edit the gitignored `terraform/bootstrap/terraform.tfvars` (keep your existing lines) and add, with real values:

```hcl
domain                 = "<your domain>"
home_lab_zone_id       = "<the zone id, edge variable existing_zone_id>"
owner_role_arn_pattern = "arn:aws:iam::<account id>:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_<your permission set>_*"
ca_cert_pem            = <<-EOT
  -----BEGIN CERTIFICATE-----
  (the public CA certificate, same value as the edge variable ca_cert_pem)
  -----END CERTIFICATE-----
EOT
pki_generation         = "gen-1"        # the value the edge workspace has today
duplicate_zone_ids     = []             # the same list as the edge workspace
allow_legacy_ssm_key   = true           # migration window: the Pi host role may still decrypt with the old key
adopt_from_edge        = true           # import the live identity instead of creating it
adopt_ids = {
  trust_anchor_id    = "<uuid>"         # the part after the last slash of the edge output trust_anchor_arn
  traefik_profile_id = "<uuid>"         # ... of profile_arn
  pi_host_profile_id = "<uuid>"         # ... of host_profile_arn
}
# enable_audit_logging = true           # only if the account has no CloudTrail trail (SEC-L1); see section 5
```

The UUIDs are in the existing edge outputs: `terraform -chdir=terraform/edge output` (after `terraform login`). Keep the owner SSO role pattern as exact as you can; it grants
only ENCRYPT through SSM, never decrypt.

```bash
aws sso login --profile henniefrancis
cd terraform/bootstrap && terraform init && terraform plan -out tfplan
```

**Read the plan before applying. It must show exactly:**

- 7 imports (trust anchor, two profiles, two roles, two role policies) and **no destroy and no "must be replaced" anywhere**;
- changes in place to: the `home-lab-pi-host` role policy (new key ARN and encryption-context condition, plus the legacy-key statement), the apply role's inline policy `scoped-write`
  (narrower), and possibly the roles' trust policy only if its JSON differs cosmetically (the conditions must be the same as today);
- additions: `aws_kms_key.ssm`, `aws_kms_alias.ssm`, and, if enabled, the audit resources.

If anything is destroyed or replaced, stop and do not apply. Then:

```bash
terraform apply tfplan
```

Confirm the new key and the identity: `terraform output ssm_kms_key_alias` prints `alias/home-lab-ssm`.

## 3. Re-set every secret under the new key (owner, laptop)

A write-only value cannot be re-encrypted by Terraform, so each SecureString is written again, now with `--key-id alias/home-lab-ssm` (the script passes it). You need each value: they
are in the password manager (S18). For each of the six parameters:

```bash
aws sso login --profile henniefrancis
scripts/set-secret.sh authentik/secret-key
scripts/set-secret.sh authentik/postgres-password
scripts/set-secret.sh traefik/breakglass-htpasswd          # value: htpasswd -nBi -C 12 admin (m2-pi-setup.md step 11)
scripts/set-secret.sh --unset tailscale/auth-key           # already UNSET after the join: re-write the placeholder under the new key
scripts/set-secret.sh --unset authentik/bootstrap-password # or set the real bootstrap password if you are still pre-first-login
scripts/set-secret.sh --unset homepage/authentik-token     # or set the token if you use the widget
```

Use the real value for any parameter that currently holds one. `authentik/secret-key` MUST be the original value (a different one invalidates every session and can break
fields Authentik encrypted with the old key). If you are unsure, recover the original from the password manager or from the previous SSM version (`aws ssm get-parameter-history`).

Verify the fetch works with the new key, on the Pi: `sudo scripts/fetch-secrets.sh --dry-run` (exit 0, no value printed). The legacy-key statement is still in place, so this passes
even for a parameter you forgot; to prove none was forgotten, list the key per parameter from the laptop without reading values:

```bash
aws ssm describe-parameters --region af-south-1 --parameter-filters "Key=Path,Option=Recursive,Values=/home-lab" \
  --query 'Parameters[?Type==`SecureString`].[Name,KeyId]' --output table
```

Every SecureString must show `alias/home-lab-ssm`.

## 4. HCP workspace `home-lab`: new variables, then `terraform/edge`

In the workspace (Variables) make these changes:

| Action | Variable |
|--------|----------|
| add (terraform) | `ra_trust_anchor_arn` = bootstrap output `trust_anchor_arn` |
| add (terraform) | `ra_acme_profile_arn` = bootstrap output `traefik_profile_arn` |
| add (terraform) | `ra_acme_role_arn` = bootstrap output `dns01_role_arn` |
| delete | `ca_cert_pem` and `pki_generation` (they belong to bootstrap now) |
| keep | everything else (`existing_zone_id`, `domain`, ...) |

Use `terraform -chdir=terraform/bootstrap output -raw <name>`. Then queue a plan for `terraform/edge` (plan role). **Before approving the apply, check the plan:**

- the seven `removed` blocks show as "will be removed from the Terraform state, but will not be destroyed" for the two roles, two role policies, two profiles and the trust anchor;
- **no resource is destroyed or replaced**; the six `aws_ssm_parameter.secret` show **no change** (their `key_id` is `alias/home-lab-ssm` already, from step 3). If a SecureString
  shows an in-place `key_id` update, STOP: step 3 was incomplete for that parameter, because applying would send the placeholder over the real value. Redo step 3 for it first;
- the three `config/ra-*` String parameters show no change (same ARNs as before).

If the plan only reads "forget" and no change, apply it. This stack can no longer touch the Roles Anywhere objects, which is the point. If the apply role reports AccessDenied while
refreshing during this plan, that is the narrowed policy working: it only reads those objects; if a read is denied, tell the developer (do not re-add write permissions).

## 5. Close the migration window and optional extras (owner)

In `terraform/bootstrap/terraform.tfvars` remove `allow_legacy_ssm_key` and `adopt_from_edge`/`adopt_ids`, then plan and apply again: the only change must be the removal of the legacy
decrypt statement from the pi-host policy. After that the old AWS-managed key can no longer decrypt any `/home-lab` secret for the Pi role.

Verify on the Pi: `sudo scripts/fetch-secrets.sh --dry-run` (exit 0) and `sudo scripts/s17-identity-tests.sh` (direct `kms:Decrypt` is still denied).

Optional, SEC-L1: `enable_audit_logging = true` creates a multi-region CloudTrail trail with log file validation (S3 bucket `home-lab-audit-<account>-<region>`, versioned, AES256,
public access blocked, expires after 365 days) and an IAM Access Analyzer. First check the account has none: `aws cloudtrail describe-trails --region us-east-1` and
`aws organizations describe-organization` (an organisation trail makes this redundant). Alarms on `rolesanywhere:CreateSession` from unexpected IPs and on `ssm:GetParameter*` by other
principals are NOT built: both need a decision about your home IP (an alert on every Pi session would be pure noise) plus an SNS subscription; set them up from the CloudTrail event
history when you want them.

Route 53 Domains has no resource-level permissions, so the apply role's domain actions cannot be limited to the lab domain. It keeps only `EnableDomainAutoRenew`, `EnableDomainTransferLock`
and `UpdateTagsForDomain` (protective or metadata), and `UpdateDomainNameservers` and `DisableDomainAutoRenew` are denied. If `registered_name_servers` ever has to change, make
the change yourself with admin SSO (`aws route53domains update-domain-nameservers`), then update the workspace variable so the edge plan stays a no-op.

CAA (SEC-L5): after the production certificate exists (M6), read the Let's Encrypt account URI from `/apps/traefik/letsencrypt/acme-prod.json` on the Pi (`sudo jq -r '.le.Account.Registration.uri' ...`; it is
not a secret) and set the edge variable `acme_account_uri`; the CAA records then allow only that account and only `dns-01`. Do not set it on the staging CA.

## 6. Pi

```bash
cd /opt/home-lab
sudo git pull --ff-only                   # first time only: the old deploy.sh has no signature check; from now on use sudo scripts/deploy.sh
sudo scripts/bootstrap.sh                 # networks (authentik-auth), traefik uid 10004, the systemd units, root-owned checkout, packages
sudo gpasswd -d "$USER" docker 2>/dev/null; id -nG | tr ' ' '\n' | grep -x docker   # no output
sudo install -m 0644 -o root -g root /dev/null /etc/home-lab/allowed_signers        # then paste your signing public key (m2-pi-setup.md 3.1)
sudo scripts/preflight.sh --stage full
sudo scripts/deploy.sh                    # signed commit required; copies the routers, recreates traefik (non-root), authentik-server (authentik-auth), homepage
sudo docker rm -f socket-proxy 2>/dev/null; sudo docker network rm socket-proxy 2>/dev/null
```

Order matters for the last two lines: run `deploy.sh` first (it removes the orphaned `socket-proxy` container), then remove the network. After the deploy, check
`sudo docker ps --format '{{.Names}} {{.Status}}'` (traefik, ra-helper, authentik-*, homepage healthy), browse `https://traefik.<domain>/` and `https://dashboard.<domain>/`, and run
`sudo scripts/breakglass.sh on 10`, test `bg-traefik.<domain>`, `sudo scripts/breakglass.sh off`.

The ACME storage directory is re-owned to uid 10004 by `bootstrap.sh`; if Traefik logs "permission denied" on `/letsencrypt`, run `sudo chown -R 10004:10004 /apps/traefik/letsencrypt`.

## 7. GitHub, Tailscale and Authentik settings (owner only: cannot be done from the repo)

- GitHub (when the repo goes public; branch protection is unavailable on a private free repo): ruleset on `main` (block force-push and deletion, require a pull request or owner bypass,
  **require status checks `checks` and `secret-scan`, require signed commits**); Settings, Code security: Dependabot alerts and security updates, secret scanning and push protection, private
  vulnerability reporting, code scanning default setup; Actions: allow GitHub-owned and the two pinned third-party actions only (or require SHA pinning), approval for all outside collaborators'
  fork runs; keep the default workflow token read-only; hardware-key or passkey 2FA on the account; delete the Pi deploy key and clone over HTTPS after M6.
- Tailscale: confirm the live ACL equals `tailscale/policy.example.hujson` and that device sharing is off.
- Authentik: `m4-authentik.md` section 8 (named admin, retire `akadmin`, event retention, no recovery flow).
- Raspberry Pi ID: 2FA with a passkey; disable Pi Connect remote shell when not needed.

## Rollback

- Bootstrap: the imports and the key are additive; to go back, restore the edge layout from git history and delete the bootstrap-managed copies from state (`terraform state rm`), never `destroy`
  (the objects have `prevent_destroy`). The key has a 30 day deletion window.
- Edge: revert the commit; the `removed` blocks only forgot state, so re-importing needs the original import commands (see the old `imports.tf` pattern) and is rarely wanted.
- Pi: `sudo git checkout <previous signed commit>` then `sudo scripts/deploy.sh --no-git`; the break-glass router and a manual `docker compose up` of the older stack work as before.
