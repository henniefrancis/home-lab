# Runbook: alerting (K4)

Nothing used to tell a person that the certificate Traefik serves was about to expire (Let's Encrypt stopped sending expiry emails in 2025, and with a long HSTS an expired certificate is a hard outage).
Now a daily check mails you through AWS SNS.

```
systemd timer (daily) -> home-lab-cert-expiry.service -> scripts/alert.sh check
      |-> scripts/cert-expiry.sh          the two Roles Anywhere certificates (warn < 30 days, fail < 14 days)
      |-> scripts/served-cert-check.sh    the certificate Traefik really serves for dashboard.<domain> (warn < 21 days, fail < 7 days, wrong name, no answer)
      '-> on WARN or FAIL: scripts/lib/alert.sh -> aws sns publish (Roles Anywhere, role home-lab-pi-host) -> SNS topic home-lab-alerts -> your email
OnFailure= -> home-lab-alert-failure@.service -> scripts/alert.sh unit-failed   (the check itself crashed; skipped when the check already mailed)
```

- At most **one alert per check per day** (state file `/var/lib/home-lab/alert-<key>.last`). The unit still fails with the check's exit code, so `systemctl --failed` shows it even when the mail could not be sent.
- The Pi can only `sns:Publish` to this one topic (`terraform/bootstrap/identity.tf`, statement `PublishHomeLabAlerts`). No other principal gains an SNS right.
- The topic uses the AWS-managed key `alias/aws/sns`, not the home-lab CMK: the CMK policy denies `kms:Decrypt` to everyone except the Pi host role, which would stop SNS from delivering. An alert holds no secret (check name and days left).
- Thresholds: `SERVED_CERT_WARN_DAYS` (default 21) and `SERVED_CERT_CRIT_DAYS` (default 7); set them with a systemd drop-in (`sudo systemctl edit home-lab-cert-expiry.service`, `[Service]` `Environment=SERVED_CERT_WARN_DAYS=14`).
- Cost: SNS email is free at this volume.

## One-time setup (owner)

1. Laptop, `terraform/bootstrap` (admin SSO, local, the stack that owns the Pi roles): add `alert_email = "<your address>"` to the gitignored `terraform.tfvars`, then `terraform plan` and `terraform apply`.
   It creates the topic `home-lab-alerts`, the email subscription and the `sns:Publish` statement on `home-lab-pi-host`. No HCP workspace change is needed: the HCP roles have no SNS access by design.
2. **Confirm the subscription.** AWS mails "AWS Notification - Subscription Confirmation" to that address; click **Confirm subscription**. Until then nothing is delivered (the subscription shows as "pending confirmation" in the SNS console). Check the spam folder.
3. Laptop: `scripts/render-aws-env.sh` now prints a sixth line, `ALERT_TOPIC_ARN=...`. Add that line to `/etc/home-lab/aws.env` on the Pi (root, mode 0600, same file as the `RA_*` lines):
   `sudo nano /etc/home-lab/aws.env`, then `stat -c '%a %u' /etc/home-lab/aws.env` must still say `600 0`.
4. Pi: deploy the release that contains this feature (`sudo scripts/deploy.sh`, see `release-and-deploy.md`), then install the new unit files: `sudo scripts/bootstrap.sh` (idempotent; it rewrites the units, adds `home-lab-alert-failure@.service` and reloads systemd).
5. Test (below), then `sudo scripts/preflight.sh --stage full`: `alert-topic` and `served-cert` must be PASS.

## Test alert (one command)

```bash
sudo scripts/alert.sh test
```

Prints `alert published (SNS message id ...)` and an email "home-lab TEST alert" arrives within a minute. A test mail is not rate limited.
If it fails, the message says why:

| Message | Meaning | Fix |
|---|---|---|
| `ALERT_TOPIC_ARN is missing or malformed` | step 3 not done | add the line to `/etc/home-lab/aws.env` |
| `publish failed: ... AccessDenied` | the apply of step 1 has not happened, or `home-lab-pi-host` lacks the statement | apply `terraform/bootstrap`; check `PublishHomeLabAlerts` in the role policy |
| `publish failed: ... KMSAccessDenied` or `NotFound` | topic key or ARN wrong | compare `ALERT_TOPIC_ARN` with `terraform output alert_topic_arn` |
| `publish failed: ... certificate` or `Unable to locate credentials` | Roles Anywhere cannot issue a session (certificate expired, clock wrong, wrong generation) | `sudo scripts/cert-expiry.sh`, `timedatectl`, `pi-recovery.md` |
| published, but no mail | the subscription is still pending, or the mail is in spam | confirm it (step 2) |

Also test the unit end to end once: `sudo systemctl start home-lab-cert-expiry.service` (exit 0 if both checks pass; `journalctl -u home-lab-cert-expiry -n 30`).

## What to do on each alert

Subject `home-lab WARNING: ...` is the early warning (act this week); `home-lab CRITICAL: ...` means act now. Every mail names the check and the host.

| Check in the mail | Meaning | What to do |
|---|---|---|
| `certificate served by Traefik`, expires in N days (WARN under 21, CRITICAL under 7) | Traefik is not renewing the wildcard (it should renew at 30 days left) | On the Pi: `sudo docker logs traefik --since 24h \| grep -i -E 'acme\|renew\|error'`; `sudo docker logs ra-helper --since 24h`. Typical causes: Roles Anywhere certificate expired (the other alert), DNS-01 role denied, Let's Encrypt rate limit or outage (`status.letsencrypt.org`), CAA record not allowing the CA account. Fix the cause, then `sudo scripts/deploy.sh --recreate traefik` and re-run `sudo scripts/served-cert-check.sh`. Last resort while you debug: `m3-traefik-staging.md` (`acme.json` handling) and, to reach the dashboard, `sudo scripts/breakglass.sh on` (LAN only; off again afterwards). |
| `certificate served by Traefik`, does not cover that name | Traefik serves its default self-signed certificate: the ACME order failed or `acme.json` is empty | Same logs as above; check `DOMAIN` in `/apps/secrets/runtime.env` and the router `tls.domains` in `traefik/dynamic`; recreate Traefik after fixing |
| `certificate served by Traefik`, no TLS certificate | Traefik is down or not listening on 443 | `sudo docker compose -p home-lab ps`; `sudo scripts/deploy.sh --only traefik` |
| `Pi Roles Anywhere certificates`, WARN (under 30 days) | the `traefik` or `host` certificate (1 year) will expire | `m2-pi-setup.md`, "Renewal": new CSR on the Pi, sign on the offline laptop CA, install. Do it this month |
| `Pi Roles Anywhere certificates`, FAIL (missing, expired, not valid yet, under 14 days) | secret fetch, DNS-01 renewal and this very alert path will stop working | Reissue now (`m2-pi-setup.md`, "Renewal"). "NOT VALID YET" means the Pi clock is wrong: `timedatectl`, fix NTP, do not reissue |
| `home-lab-cert-expiry.service failed` (unit-failed) | the check itself crashed (no `openssl`, unreadable PKI directory, bad threshold) | `systemctl status home-lab-cert-expiry`; `journalctl -u home-lab-cert-expiry -n 50`; run `sudo scripts/alert.sh check` by hand |

If you get no alert but expect one: `sudo scripts/alert.sh check; echo $?`, `ls -l /var/lib/home-lab/` (one `alert-*.last` file per key; delete one to allow another mail today), `systemctl list-timers home-lab-cert-expiry.timer`.

## Not covered

Only certificates and the check unit are watched. Nothing yet alerts on a down container, a full SD card or a failed backup (K5); do not read silence as health. SNS email is not a pager: it reaches you when you read mail.
