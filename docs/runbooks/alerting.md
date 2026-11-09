# Runbook: alerting (K4)

Nothing used to tell a person that the certificate Traefik serves was about to expire (Let's Encrypt stopped sending expiry emails in 2025, and with a long HSTS an expired certificate is a hard outage).
Now a daily check mails you through AWS SNS, and a monthly test mail proves the path itself still works.

```
systemd timer (daily) -> home-lab-cert-expiry.service -> scripts/alert.sh check
      |-> scripts/cert-expiry.sh          the two Roles Anywhere certificates (warn < 30 days, fail < 14 days)
      |-> scripts/served-cert-check.sh    the certificate Traefik really serves for dashboard.<domain>
      '-> on WARN or FAIL: scripts/lib/alert.sh -> aws sns publish (Roles Anywhere, role home-lab-pi-host) -> SNS topic home-lab-alerts -> your email
OnFailure= -> home-lab-alert-failure@.service -> scripts/alert.sh unit-failed   (the check itself crashed; skipped when the check already mailed for that unit)
systemd timer (monthly) -> home-lab-alert-test.service -> scripts/alert.sh test    (the heartbeat: no mail for a month means the path is dead)
```

What the served-certificate check verifies: a certificate is served, it is valid now (not expired, not "not valid yet"), it covers the host name, at least 21 days are left (FAIL under 7),
and the **issuer matches the environment `config/lab.env` asks for** (`ACME_CA_SERVER`): with production configured it must chain to a publicly trusted root and must not be a staging certificate; with staging configured it should be a staging one.
Preflight also fails when `ACME_ENV` and `ACME_CA_SERVER` disagree (a half-applied M6 step 1).

How alerts behave:

- At most **one alert per check and state per day** (state files `/var/lib/home-lab/alert-<check>-<state>.last`; states: `warn`, `crit`, `down`, `error`). A later escalation (warn, then critical) mails again the same day. A timestamp that is in the future, not a plain number or implausible is ignored, so a Pi with a wrong clock cannot silence alerts. The limit allows 2 hours of slack, so a standing failure mails daily, not every 24 to 48 hours.
- **Down is not alarming at once.** If nothing answers on port 443 (Traefik down) the first run only records it; a mail follows only if it is still down at a later run at least an hour on. A Pi that booted less than 10 minutes ago does not mail. A planned stop or reboot therefore stays quiet.
- A **broken check** (for example a bad `SERVED_CERT_WARN_DAYS` value, or openssl missing) mails "the check could not run" instead of pretending to be a certificate warning.
- The unit still fails with the check's exit code (`systemctl --failed`), even when the mail could not be sent.
- The Pi can only `sns:Publish` to this one topic (`terraform/bootstrap/identity.tf`, statement `PublishHomeLabAlerts`), and the topic has its own explicit policy (TLS only, publish for the Pi role and the owner role only, subscribe and management for the owner only: `terraform/bootstrap/alerts.tf`). No other principal gains an SNS right.
- The topic uses the AWS-managed key `alias/aws/sns`, not the home-lab CMK: the CMK policy denies `kms:Decrypt` to everyone except the Pi host role, which would stop SNS from delivering. An alert holds no secret.
- **Alert text rules:** names the check, host name, dates and issuer only. Never IPs, tailnet names, tokens or file contents. **Never click a link in an alert mail**: an alert only ever names a runbook path. A stolen Pi host certificate could send a forged alert from the real SNS sender; it can already read the Pi's secrets, so this adds little, but treat any alert mail with a link as hostile.
- Thresholds: `SERVED_CERT_WARN_DAYS` (default 21) and `SERVED_CERT_CRIT_DAYS` (default 7); set them with a systemd drop-in (`sudo systemctl edit home-lab-cert-expiry.service`, `[Service]` `Environment=SERVED_CERT_WARN_DAYS=14`).
- The email address is stored in clear in the Terraform state of the HCP workspace `home-lab-bootstrap` (local execution; `sensitive` only hides it in output). Accepted: restrict workspace membership; the address is never committed.
- Cost: SNS email is free at this volume.

## One-time setup (owner)

1. Laptop, `terraform/bootstrap` (admin SSO, local execution, the stack that owns the Pi roles): add `alert_email = "<your address>"` to the gitignored `terraform.tfvars`, then `terraform plan` and `terraform apply`.
   It creates the topic `home-lab-alerts`, its topic policy, the email subscription and the `sns:Publish` statement on `home-lab-pi-host`. No HCP edge-workspace change is needed: the HCP roles have no SNS access by design.
2. **Confirm the subscription promptly.** AWS mails "AWS Notification - Subscription Confirmation" to that address; click **Confirm subscription** (check spam). Unconfirmed subscriptions are deleted by AWS after a short window; if it lapsed, run `terraform apply -replace=aws_sns_topic_subscription.alerts_email` and confirm the new mail.
   Allow-list the AWS sender in your mail client. **Never click "Unsubscribe" in an alert mail** (it ends the subscription for good; mail scanners that open links can do the same, so if alerts stop, suspect this first and re-create the subscription as above).
3. Laptop: `scripts/render-aws-env.sh` now prints a sixth line, `ALERT_TOPIC_ARN=...`. Add that line to `/etc/home-lab/aws.env` on the Pi (root, mode 0600, same file as the `RA_*` lines):
   `sudo nano /etc/home-lab/aws.env`, then `stat -c '%a %u' /etc/home-lab/aws.env` must still say `600 0`. No quotes, no spaces.
4. Pi: deploy the release that contains this feature (`sudo scripts/deploy.sh`, see `release-and-deploy.md`), then **install the units**: `sudo scripts/bootstrap.sh` (idempotent; renders every `scripts/systemd/*` unit, reloads systemd, enables the daily check and the monthly test).
   `deploy.sh` never touches `/etc/systemd`. It warns when an installed unit differs from the repository, and `sudo scripts/preflight.sh --stage full` **fails** (`systemd-units`) until you run `bootstrap.sh`. Do this after every release that changes a file in `scripts/systemd/`.
5. Test (below), then `sudo scripts/preflight.sh --stage full`: `alert-topic`, `served-cert`, `systemd-units` and `alert-heartbeat` must be PASS.
6. Start the real unit once: `sudo systemctl start home-lab-cert-expiry.service; echo $?` then `journalctl -u home-lab-cert-expiry -n 30`. The units are sandboxed (read-only file system except `/var/lib/home-lab`, no devices, limited system calls and address families).
   If a unit fails with `Operation not permitted` or `Bad system call`, a restriction is too tight for this Pi: `sudo systemctl edit <unit>` and clear the one setting (for example `[Service]` `SystemCallFilter=`), then tell the maintainer so the repository copy is corrected. `systemd-analyze security home-lab-cert-expiry.service` shows the exposure score.

## Test alert (one command)

```bash
sudo scripts/alert.sh test
```

Prints `alert published (SNS message id ...)` and an email "home-lab TEST alert" arrives within a minute. A test mail is not rate limited.
If it fails, the message says why:

| Message | Meaning | Fix |
|---|---|---|
| `ALERT_TOPIC_ARN is missing or malformed` | step 3 not done, or the value has quotes or spaces | add the plain line to `/etc/home-lab/aws.env` |
| `publish failed: ... AccessDenied` | the apply of step 1 has not happened, or `home-lab-pi-host` lacks the statement | apply `terraform/bootstrap`; check `PublishHomeLabAlerts` in the role policy and the topic policy |
| `publish failed: ... KMSAccessDenied` | the Pi role may not use the AWS-managed SNS key | see "If the test says KMS access denied" below; do not touch the home-lab CMK |
| `publish failed: ... NotFound` | topic ARN wrong | compare `ALERT_TOPIC_ARN` with `terraform output alert_topic_arn` |
| `publish failed: ... certificate` or `Unable to locate credentials` | Roles Anywhere cannot issue a session (certificate expired, clock wrong, wrong generation) | `sudo scripts/cert-expiry.sh`, `timedatectl`, `pi-recovery.md` |
| published, but no mail | the subscription is pending, was deleted, or the mail is in spam | confirm or re-create it (setup step 2) |

### If the test says KMS access denied

The AWS-managed key `alias/aws/sns` normally lets principals of the account publish through SNS, so this should not happen. If it does, add exactly this to the Pi host role policy in `terraform/bootstrap/identity.tf` (owner apply), and nothing broader:

- actions `kms:GenerateDataKey*` and `kms:Decrypt`,
- resource: the ARN of the key behind `alias/aws/sns` in `af-south-1` (look it up with `terraform console` or the KMS console, read only),
- condition `kms:ViaService` equal to `sns.af-south-1.amazonaws.com`.

Never `kms:*`, never a wildcard resource, and never change the home-lab key `alias/home-lab-ssm` for this. Update the `alerts_only_pi_host_can_publish` test in `terraform/bootstrap/tests/policies.tftest.hcl` in the same change. Then `terraform apply` and re-run the test.

## Heartbeat: the monthly test mail

`home-lab-alert-test.timer` sends a test mail once a month. **If a month passes without it, the path is dead** (pending or deleted subscription, filtered sender, expired Pi certificate, wrong clock): run `sudo scripts/alert.sh test` and follow the table above.
Preflight warns (`alert-heartbeat`) when no test has been published for 35 days. A published test cannot prove the mail arrived; the mail in your inbox is that proof, so note the date of the last one you saw.
Before every HSTS raise (`m6-go-live.md`, step 4) a test mail must have **arrived within the last 7 days**.
Optional later: subscribe a second endpoint (SMS or a push service) to the topic, so one dead mailbox does not blind you.

## What to do on each alert

Subject `home-lab WARNING: ...` is the early warning (act this week); `home-lab CRITICAL: ...` means act now. Every mail names the check and the host.

| Check in the mail | Meaning | What to do |
|---|---|---|
| `certificate served by Traefik`, expires in N days (WARN under 21, CRITICAL under 7) | Traefik is not renewing the wildcard (it should renew at 30 days left) | On the Pi: `sudo docker logs traefik --since 24h \| grep -i -E 'acme\|renew\|error'`; `sudo docker logs ra-helper --since 24h`. Typical causes: Roles Anywhere certificate expired (the other alert), DNS-01 role denied, Let's Encrypt rate limit or outage (`status.letsencrypt.org`), CAA record not allowing the CA account. Fix the cause, then `sudo scripts/deploy.sh --recreate traefik` and re-run `sudo scripts/served-cert-check.sh`. While you debug, `sudo scripts/breakglass.sh on` reaches the Traefik dashboard (LAN only; off again afterwards). |
| `certificate served by Traefik`, does not cover that name | Traefik serves its default self-signed certificate: the ACME order failed or the store is empty | Same logs as above; check `DOMAIN` in `/apps/secrets/runtime.env` and the router `tls.domains` in `traefik/dynamic`; recreate Traefik after fixing |
| `certificate served by Traefik`, STAGING certificate with production configured, or does not chain to a trusted root | Traefik still serves the staging store or a fallback certificate | `m6-go-live.md` step 1: `ACME_ENV` and `ACME_CA_SERVER` must both say production, then `sudo scripts/deploy.sh --recreate traefik`; look in `/apps/traefik/letsencrypt/` for `acme-prod.json` |
| `certificate served by Traefik`, NOT VALID YET | the Pi clock is wrong (no RTC) | `timedatectl`, fix NTP; do not touch certificates |
| `certificate served by Traefik`, no TLS certificate (arrives only if it stays down for an hour or more) | Traefik is down or not listening on 443 | `sudo docker compose -p home-lab ps`; `sudo scripts/deploy.sh --only traefik` |
| `Pi Roles Anywhere certificates`, WARN (under 30 days) | the `traefik` or `host` certificate (1 year) will expire | `m2-pi-setup.md`, "Renewal": new CSR on the Pi, sign on the offline laptop CA, install. Do it this month |
| `Pi Roles Anywhere certificates`, FAIL (missing, expired, not valid yet, under 14 days) | secret fetch, DNS-01 renewal and this very alert path will stop working | Reissue now (`m2-pi-setup.md`, "Renewal"). "NOT VALID YET" means the Pi clock is wrong: `timedatectl`, fix NTP, do not reissue |
| `(the check could not run)` | the check itself broke (bad setting, openssl missing, unreadable file) | `sudo scripts/alert.sh check` by hand shows the message; fix the setting in the unit drop-in |
| `<unit> failed` (unit-failed) | a unit crashed before it could report | `systemctl status <unit>`; `journalctl -u <unit> -n 50`; run `sudo scripts/alert.sh check` by hand |
| `a unit failed` (name not usable) | a failed unit with an unusual name | `systemctl --failed` |

If you get no alert but expect one: `sudo scripts/alert.sh check; echo $?`, `ls -l /var/lib/home-lab/` (one `alert-*.last` file per key and state; delete one to allow another mail today), `systemctl list-timers 'home-lab-*'`, and run `sudo scripts/alert.sh test`.

## Not covered

Only certificates, the check units and the alert path itself are watched. Nothing yet alerts on a down container, a full SD card or a failed backup (K5); do not read silence as health. SNS email is not a pager: it reaches you when you read mail.
SNS Publish is a CloudTrail data event; if you turn on audit logging (N7) and want these calls recorded, add data events for the topic.
