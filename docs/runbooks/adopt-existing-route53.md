# Runbook: adopt the existing Route 53 setup (milestone M1)

The domain's hosted zone, records and registered nameservers were created by hand before Terraform existed. They are adopted with
`import` blocks. Nothing is recreated and the adoption plan must be a no-op apart from tag additions.

**Golden rule:** no console or CLI changes to Route 53 or Route 53 Domains from now on. Every DNS change is a reviewed Terraform
plan. If something urgent happens before M1 completes, write it down so it can be reconciled here.

## How real values stay out of the public repo

Nothing real is committed. The zone ID, record names and values, and registered nameservers are HCP **workspace variables**.
`scripts/aws-preflight.sh --snapshot` writes ready-to-paste values into the gitignored `adopt-snapshot/` directory
(`scalar-variables.txt`, `existing_records.hcl`, `zone-records.json`). Never commit that directory.

## Steps

| Step | Action | Check |
|------|--------|-------|
| AD1 | Console freeze. Run `DOMAIN=<your-domain> scripts/aws-preflight.sh --snapshot`. | Exactly one DELEGATED zone whose NS equal the registered NS and the public `dig NS`; DS count 0. |
| AD2 | With the owner, classify each inventoried record KEEP, REPLACE or DROP; list collisions with planned records; list duplicate zones. Keep the decisions in the owner's private notes (generic wording only here). | Every record has a decision. |
| AD3 | Set the workspace variables from the snapshot: `existing_zone_id`, `existing_zone_comment`, `registered_name_servers` (exact order), `domain_auto_renew`, `domain_transfer_lock`, `existing_records`, `duplicate_zone_ids`. Leave `create_planned_records=false`, `create_ssm_parameters=false`, and `pi_tailnet_ipv4`, `ca_cert_pem` and `budget_email` unset. | Values copied, not retyped. |
| AD4 | Remote `terraform plan` of `terraform/edge`. | Imports only; `0 to destroy`, `0 to replace`; no attribute change except tag additions; the `registered_ns_match_zone` check passes. If anything else appears, fix the variables. Never apply a diff you do not understand. |
| AD5 | Owner approves; apply. | Public DNS answers unchanged for every inventoried record (`dig` the list); registered NS unchanged; CloudTrail shows no `UpdateDomainNameservers`. |
| AD6 | Follow-up reviewed applies, one concern each: (a) `create_planned_records=true` for the `www` placeholder and CAA; (b) REPLACE edits; (c) DROP removals (delete the map entries); (d) remove duplicate zones by deleting their IDs from `duplicate_zone_ids`; (e) optional zone comment change. | Each plan shows only the intended change; DNS checked after each apply. |
| AD7 | A fresh plan shows **No changes**. | The M1 gate. |

Follow-up applies after AD7 (separate reviewed plans): planned records, SSM parameters (`create_ssm_parameters=true`, then the verification in [[secrets-ssm]]), the budget (`budget_email`), and in M2 the Roles Anywhere objects (`ca_cert_pem`).

## Collisions with planned records

The planned records are `*` A (needs `pi_tailnet_ipv4`), `www` TXT and apex CAA. If a record already exists at one of those addresses,
leave it out of `existing_records` and set the matching flag in `adopt_planned_records` (`wildcard_a`, `www_txt`, `apex_caa`). The
existing record is then imported at the planned resource address, and any value change appears in a separate reviewed plan.

## Registered domain notes

- The domain is adopted with `aws_route53domains_registered_domain`; the other domain resource, which can register or renew, is banned (CI guard on `*.tf`).
- Contacts and privacy are not managed.
- Some TLDs (for example `co.za`) have no transfer lock: the preflight shows `TransferLock=null`; keep `domain_transfer_lock` null.
- DNSSEC is off and is a Phase 2 item.

## Never managed

Apex NS and SOA (owned by the zone) and `_acme-challenge` (owned by Traefik at issuance).

## Email and other services using the zone

The inventory may include records for services such as mail (MX, SPF, DKIM, DMARC) or device enrolment. Treat them as KEEP unless the
owner explicitly decides otherwise: dropping them breaks mail or enrolment.

## Recovery from a bad apply

Every change is a reviewed plan: revert the variable or code and apply again. The zone and registered domain cannot be destroyed
(`prevent_destroy`; destroy plans disabled in the workspace). A registered-NS change is blocked by the check unless intentional.
