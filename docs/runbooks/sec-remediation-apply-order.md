# Runbook: security and QA remediation, owner apply order (2026-11-08)

Audience: the owner. Everything here is a placeholder or a command shape; real values stay in the gitignored `terraform/bootstrap/terraform.tfvars`, the HCP workspace
variables and the password manager. Nothing in this runbook has been run against AWS, HCP or the Pi: the code was validated offline (see the findings resolution note).

What changed, in one paragraph: the Pi's AWS identity (Roles Anywhere trust anchor, two profiles, the DNS-01 role and the Pi-host role) moved from `terraform/edge`
(applied by the HCP apply role) to `terraform/bootstrap` (applied by you, admin SSO). The HCP apply role lost every `iam:*` and `rolesanywhere:*` write permission, is
scoped to the home-lab hosted zone, and can no longer decrypt secrets. SecureStrings move to a customer-managed key and become owner-managed (ADR-013): Terraform no longer touches them. The Docker socket proxy is gone, deploys verify a
signature, and the checkout is root-owned.

Why "remove the permission" and not a permissions boundary: IAM conditions cannot constrain the contents of a trust policy, so a boundary on `iam:UpdateAssumeRolePolicy`
or `iam:CreateRole` cannot make role edits safe, and a boundary plus a deny list is more moving parts than simply moving the roles to the stack you apply yourself.
The two roles change rarely; an admin SSO apply is the right place for them.

## Order at a glance

| # | Who | What | Reversible? |
|---|-----|------|-------------|
| 0 | Laptop | Pull the commits, run the offline self-tests, set up commit signing (section 1) | yes |
| 1 | Owner | `terraform/bootstrap` apply with the migration flags (section 2): imports the live identity, creates the KMS key, narrows the apply role | yes (the old edge layout still has the objects in its state until step 3) |
| 2 | Owner | Check the six secrets are on the new key with `set-secret.sh --check` (section 3) | yes |
| 3 | Owner or lead | Second bootstrap apply (3 in-place changes), HCP variables, then plan and apply `terraform/edge`: 13 objects forgotten (section 4) | yes |
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
owner_role_arn_pattern = "arn:aws:iam::<account id>:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_<your permission set>_*"
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

The UUIDs are in the existing edge outputs: `terraform -chdir=terraform/edge output` (after `terraform login`). The IAM Identity Center role path has NO region segment (`.../aws-reserved/sso.amazonaws.com/AWSReservedSSO_<set>_<id>`), so do not put `/*/` in it. Keep the pattern as exact as you can; it grants
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

## 3. Check the secrets are on the new key (owner, laptop)

The six SecureStrings are owner-managed from now on (ADR-013), so there is no Terraform step for them. If you already re-set them with `set-secret.sh` (they then carry `alias/home-lab-ssm`), just verify:

```bash
aws sso login --profile henniefrancis
scripts/set-secret.sh --check
```

It prints each expected SecureString with its key and version (never a value) and exits 1 when one is missing, is not a SecureString, or is not on `alias/home-lab-ssm`. For a missing one:
`scripts/set-secret.sh --create <name>` then set it; for one on the wrong key, set the value again (use the ORIGINAL value, `authentik/secret-key` especially; it is in the password manager).

## 4. Narrow the HCP roles (second bootstrap apply), then `terraform/edge`

**4a. Bootstrap, second apply.** The code now also scopes the HCP roles' SSM access to `/home-lab/config/*`, removes their KMS permissions (the apply role's key-user statement is gone from the key policy) and keeps only
the explicit decrypt deny. `terraform -chdir=terraform/bootstrap plan -out tfplan` must show **0 to add, 3 to change, 0 to destroy** (in place: the plan role policy `read-only`, the apply role policy
`scoped-write`, and the KMS key policy; nothing else). Apply it. The migration flags (`adopt_from_edge`, `allow_legacy_ssm_key`) can still be set or already removed: removing them in the same apply is fine
(the extra change is then the pi-host policy, 4 to change).

**4b. HCP workspace variables** (if not done yet):

| Action | Variable |
|--------|----------|
| add (terraform) | `ra_trust_anchor_arn` = bootstrap output `trust_anchor_arn` |
| add (terraform) | `ra_acme_profile_arn` = bootstrap output `traefik_profile_arn` |
| add (terraform) | `ra_acme_role_arn` = bootstrap output `dns01_role_arn` |
| delete | `ca_cert_pem` and `pki_generation` |

**4c. Edge plan.** Queue a plan for `terraform/edge` (plan role). It must show **0 to add, 0 to change, 0 to destroy** and a warning "Some objects will no longer be managed by Terraform" listing exactly **13 objects**
(removed from state, not deleted): the 6 `aws_ssm_parameter.secret[...]` and the 7 identity objects (`aws_iam_role.traefik_dns01`, `aws_iam_role.pi_host`, their 2 role policies, 2 Roles Anywhere profiles, the trust
anchor). If the 7 identity objects were already forgotten by an earlier apply, expect 6. The 3 `config/ra-*` and the other `/home-lab/config/*` String parameters show no change. `removed` blocks are not refreshed
(tested with a dead proxy: no API call), so the narrowed plan role does not need to read them. If anything is to be created, changed or destroyed, stop and tell the developer. Then apply.

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
