# Runbook: Pi recovery (plan section 11.3, QA review gap)

Audience: the owner. For a dead SD card or SSD, a replaced Pi, or a lost or stolen Pi. Placeholders only; real values come from the password manager, the HCP workspace and the
bootstrap outputs. Exercise it as a drill (plan Q20, Q24) following the drill checklist at the end of this file, and record it in the drill log.

What survives: AWS (Route 53, SSM secrets, the identity stack, the encrypted Authentik backups in S3), GitHub, the offline CA (laptop and its backups: the password manager attachment and a USB stick,
`ca-backup.md`), the password manager (which also holds the Authentik backup age identity). What is lost with the SD card:
`/etc/home-lab` (aws.env, the two private keys and certificates), `/apps` (Let's Encrypt state, Tailscale node key, Authentik database), the checkout.

## 0. Decide: replaced Pi, or lost or stolen Pi?

- **Lost or stolen (the SD card may be in someone else's hands):** the card holds the Roles Anywhere keys, every secret in clear, the Authentik database (password hashes, TOTP seeds, WebAuthn credentials), the Tailscale node key, the Let's Encrypt private key and a GitHub deploy key. Revoke FIRST (section 1), then rebuild; the order in section 1 matters.
- **Dead card, you still hold it or it is destroyed:** you may skip revocation and reuse the generation, but revoking is cheap, so prefer it when in doubt.

### 0.5 The recovery kit (what must be on the laptop BEFORE you need it)

Check this list at every drill. A recovery that starts by installing tools is slower and more error prone.

- **AWS:** an SSO profile with the admin role that applies `terraform/bootstrap` (`aws sso login --profile <profile>` works), and the aws CLI v2.
- **Terraform and HCP:** Terraform, `terraform login`, and `TF_CLOUD_ORGANIZATION` set (`render-aws-env.sh` and the trust anchor apply read the HCP state).
- **age** (and `age-keygen`), **Docker** (the Authentik restore test), **git** with the repository, **gh** (the deploy key) and the **commit signing key** (releases are signed; `deploy.sh` verifies).
- **openssl** and a checkout of `scripts/pki` (CA restore test, `sign.sh`).
- **Password manager items:** the CA passphrase (its own item), the CA backup attachment (copy A, a different item), the Authentik backup age identity, the break-glass and Tailscale values, and the SSO and HCP logins. Keep the password manager's own recovery (emergency kit or recovery key) printed and stored with the CA USB stick (copy B), which is kept apart from the laptop.
- **The CA USB stick** (copy B: `ca.key`, `ca.crt`, `issued.tsv`, `identity.age` the passphrase-encrypted age identity). If it does not exist yet, the password manager is the only copy: see the note at the top of `ca-backup.md` section 1.

**If the Pi and the laptop are both gone (a burglary, a fire):** recover the laptop side first, from the other places. (1) A new machine: install the tools above. (2) The password manager: sign in with its master credentials and recovery key (the emergency kit on the USB stick, or wherever you keep it). (3) AWS: `aws configure sso` for the admin role, then `terraform login`. (4) The CA: restore copy A (password manager) or copy B (stick) and test it (`ca-backup.md` sections 3 and 4); if both are gone too, `ca-backup.md` section 5. (5) The age identity: from the password manager, or decrypt `identity.age` from the stick with its passphrase. Then continue below as for a stolen Pi.

## 1. Revoke the old identity and rotate what the card held [Owner, laptop, only for a lost or stolen Pi]

Do these in this order. Steps 1 to 3 cut the thief off (minutes); step 4 and 5 rotate; step 6 comes after the Authentik restore (section 6).

1. **Roles Anywhere (stops AWS access from the card).** Disable the trust anchor: `aws rolesanywhere disable-trust-anchor --trust-anchor-id <uuid> --region af-south-1` (admin SSO), or set `enabled = false` on
   `aws_rolesanywhere_trust_anchor.ca` in `terraform/bootstrap` and apply. This stops BOTH identities (secret fetch, ACME and the backup upload) until you re-enable it in section 3 step 4. Tidy version, same apply: bump `pki_generation` (for example `gen-2`) in `terraform/bootstrap/terraform.tfvars`;
   the roles' trust policy pins the OU, so old certificates stop working for good. (Cost: both new certificates must carry `OU=gen-2`.)
2. **Other accounts the card can reach.**
   - **GitHub deploy key:** the Pi's read-only deploy key is on the card. Remove it: the repository's Settings, Deploy keys, or `gh repo deploy-key list` then `gh repo deploy-key delete <id>`. A new one is made in `m2-pi-setup.md` section 0.5 for the new Pi.
   - **Raspberry Pi Connect:** remove the old device in the Raspberry Pi Connect account (the device list of your Connect account), so the stolen card cannot offer a remote shell as your Pi.
   - **Tailscale:** in the admin console remove the old `homelab-pi` node and expire it (its node key was on the card).
3. **Stop trusting what arrived after the theft.** From now on pick Authentik backups by the rules in `authentik-backup.md` section 4: only a dump from before the incident, chosen by S3 `LastModified` and `VersionId`, test-restored in a throwaway container first. A thief with the host certificate could have uploaded a hostile "newest" dump.
4. **Rotate every SSM secret with `set-secret.sh`** (laptop; none of them needs the Pi). Do this BEFORE the rebuild, so the new containers are born with the new values:
   - `authentik/postgres-password`: set a new value now. `pg_dump -Fc` does not carry database roles, so the rebuilt PostgreSQL initialises with the new SSM value and the restore brings back data only. No `ALTER USER` or `\password` step is needed (that step in `rotate-secrets.md` is for a running Pi you still control).
   - `authentik/secret-key`: set a new value. The official Authentik configuration reference describes it only as the cookie-signing key and says changing it invalidates active sessions ([configuration](https://docs.goauthentik.io/install-config/configuration/)); it does not describe any database dependence, so the restore does not need the old key. A new key also kills every session the thief could have stolen. Verify login, MFA and a protected app after the restore (`authentik-backup.md` section 6 step 8).
   - `traefik/breakglass-htpasswd` (a new `htpasswd -nBi -C 12 admin` line), `authentik/bootstrap-password` stays UNSET, and `tailscale/auth-key` is set later in section 5 (new one-off key).
5. **The Let's Encrypt wildcard certificate.** Its private key and the ACME account key are in Traefik's storage on the card (`/apps/traefik/letsencrypt`). Let's Encrypt documents three ways to revoke a certificate ([revoking](https://letsencrypt.org/docs/revoking/)): with the issuing account key, with the certificate's private key, or with a different ACME account that proves control of every name in the certificate (DNS TXT). The first two need material that is on the stolen card, so only the third is possible from the laptop,
   and it is manual: with certbot and the Route 53 DNS plugin, request a certificate for the same names (the documented trick is to add a name that does not exist so validation runs but issuance fails), then `certbot revoke --cert-path <the certificate downloaded from crt.sh> --reason keyCompromise`. Traefik itself has no revoke command.
   **Honest assessment:** the rebuilt Pi creates a new ACME account and a new certificate on first start, and the old certificate expires on its own (90 days or less). The hostnames (`dashboard.<domain>` and the rest) point at the LAN or the tailnet, so a thief with the key could only impersonate them to someone who can already reach your network, which is a small window. Doing the revocation is correct; skipping it and relying on the short lifetime is a documented, accepted fallback for this lab. Write down which you chose in the drill log.
6. **After the Authentik restore (section 6): every user resets.** The restored password hashes and TOTP seeds were on the stolen card, so the thief may be able to crack the hashes and clone a TOTP device. For every user, including you: set a new random password (admin interface, Directory, Users, the user, set password), delete every MFA device (the same user page; the device list for TOTP and WebAuthn), then give them a recovery link (`m4-authentik.md` section 6) so they set a password and enrol MFA again.
   Also delete all tokens and app passwords (Directory, Tokens and App passwords) and re-create the one the dashboard uses (`m4-authentik.md`), and rotate the client secret of every OAuth2 provider that has one. Your own admin comes first, so you can do the rest.

## 2. Prepare the new Pi [Pi]

1. **A fresh flash** (`m2-pi-setup.md` section 0 is written for an existing Pi, so the first-boot steps are here): flash Raspberry Pi OS 64-bit with Raspberry Pi Imager, setting the login user, the SSH or password login, the Wi-Fi if any, the locale and the time zone in Imager's settings. Boot, make sure the time is right (`timedatectl`; the certificates and Roles Anywhere depend on it), sign in to Raspberry Pi Connect from the Pi (`rpi-connect signin`) and enable it, and give the Pi the same DHCP reservation (or a new one: update the router, the Tailscale node address is new anyway).
2. Follow `m2-pi-setup.md` sections 0 to 3: Docker (login user NOT in the docker group), the root-owned checkout in `/opt/home-lab` with a NEW deploy key, `preflight.sh`, `bootstrap.sh`.
   **Before `bootstrap.sh`, create the restore sentinel** (it enables the backup timer, and the first night would upload the fresh EMPTY Authentik database as the newest backup, `authentik-backup.md` section 7): `sudo install -d -m 0700 /etc/home-lab && sudo touch /etc/home-lab/restore-pending`. The nightly backup skips while it exists; you remove it after the restore (section 6).
3. Install `/etc/home-lab/allowed_signers` and check the checkout ownership and `sudo -l` (`m2-pi-setup.md` 3.1) so deploys verify; do this BEFORE the first `deploy.sh`.

## 3. New keys and certificates [Pi, then Laptop, then Pi]

1. On the Pi: `sudo scripts/pki/pi-csr.sh` (new keys; add `--generation gen-2` style flags exactly as in `m2-pi-setup.md` step 5).
2. On the laptop, with the offline CA from its backup (restore it first if the laptop was also lost, and test it with `scripts/pki/test-ca-restore.sh`: `ca-backup.md` sections 3 and 4): sign both CSRs (`scripts/pki/sign.sh`, step 6).
3. On the Pi: `sudo scripts/pki/pi-install-cert.sh traefik ...` and `host ...` (step 7). The installer refuses a certificate that is not valid yet: fix the clock first (`timedatectl`).
4. If you disabled the trust anchor in section 1, re-enable it now (`aws rolesanywhere enable-trust-anchor ...`).

## 4. `aws.env` and secrets [Laptop, then Pi]

1. Laptop: `scripts/render-aws-env.sh --generation <gen> --age-recipient age1...` (reads the bootstrap outputs; the recipient is the PUBLIC key from the password manager item "home-lab Authentik backup age identity", its `# public key:` line). It prints up to eight lines: `AWS_REGION`, `PKI_GENERATION`, `RA_TRUST_ANCHOR_ARN`, `RA_HOST_PROFILE_ARN`, `RA_HOST_ROLE_ARN`, `ALERT_TOPIC_ARN`, `BACKUP_S3_BUCKET` and `BACKUP_AGE_RECIPIENT`. A missing line is only a note on stderr, so count them. Paste them all into `/etc/home-lab/aws.env` (root 0600) as in `m2-pi-setup.md` step 10.
2. Pi: `sudo scripts/deploy.sh`. It verifies the signed commit, restores every secret from SSM (`fetch-secrets.sh`), and starts the stack. If SSM is unavailable, the password manager is the
   offline backup: use `scripts/set-secret.sh` from the laptop once AWS is back, or boot with `--offline` only if you restored the secrets directory yourself.

## 5. Tailscale [Laptop, Pi]

New one-off key: Tailscale console (tag `tag:homelab`, one-off, expires in a day), `scripts/set-secret.sh tailscale/auth-key`, `sudo scripts/deploy.sh --recreate tailscale`, check `status`,
then `scripts/set-secret.sh --unset tailscale/auth-key` and `sudo scripts/deploy.sh --recreate tailscale` (the secret file is replaced, the container only changes when recreated). Remove the old node in the admin console. The tailnet address changes: update the edge variable
`pi_tailnet_ipv4` and apply `terraform/edge` (the wildcard A record).

## 6. Authentik

The database lives on the card, but a nightly encrypted copy is in S3 (K5, `authentik-backup.md`). Users, password hashes and MFA devices come back from it.

1. **With a backup (normal path):** `deploy.sh` first starts a fresh, empty Authentik (using the PostgreSQL password that SSM now holds), then follow `authentik-backup.md` sections 3 to 6, in short:
   choose the dump by S3 `LastModified` and `VersionId` (never by name, one version per key, from before the incident after a theft), test-restore it into a throwaway container with `--network none` and look at the users, then stream it to the Pi through a one-off age key in `/run` and a presigned URL
   (the Pi cannot read S3, Raspberry Pi Connect has no file transfer and the tailnet allows only 80 and 443), stop `authentik-server` and `authentik-worker`, `pg_restore --clean --if-exists` into the postgres container, start again, remove `/etc/home-lab/restore-pending`, and log in.
   Restore into the same Authentik version or newer. The Authentik secret key does not have to match the one in use when the dump was taken (it signs cookies; section 1 step 4); after a theft you rotated it on purpose.
2. **After a theft, section 1 step 6 follows:** reset every user and delete the tokens.
3. **Fallback, no usable backup (blueprint path):** the blueprint rebuilds groups, providers, applications and the MFA policy, but **users and MFA devices are gone**.
   Set `authentik/bootstrap-password` (`set-secret.sh`), `sudo scripts/deploy.sh --recreate authentik`, log in as `akadmin`, create your named admin, enrol MFA, deactivate `akadmin` again, set the bootstrap password back to UNSET
   (`m4-authentik.md` section 8, then `sudo scripts/deploy.sh --recreate authentik` again). Re-create the family accounts and re-enrol their MFA. Remove the sentinel in this case too (`sudo rm /etc/home-lab/restore-pending`).

Preflight shows `backup-last` WARN "never" until the first nightly run or a manual `sudo systemctl start home-lab-backup-authentik.service` after the sentinel is gone. A rebuilt Pi needs `age` (`bootstrap.sh` installs it) and the two `BACKUP_*` lines in `aws.env` (section 4).

## 7. Let's Encrypt certificate

The ACME storage is gone: Traefik requests a fresh wildcard certificate on first start (DNS-01 through the DNS-01 role). On production, mind the Let's Encrypt rate limits (5 duplicate
certificates per week): if you rebuild repeatedly while testing, switch `ACME_ENV` to staging first (`config/lab.env`).

## 8. Verify

`sudo scripts/preflight.sh --stage full`, `sudo scripts/s17-identity-tests.sh`, `sudo scripts/cert-expiry.sh`, browse `traefik.<domain>` and `dashboard.<domain>`, and
`sudo scripts/breakglass.sh on 10` then `off`. Then run the drill checklist and record the drill below.

## 9. Offline boot drill (plan Q19)

Unplug the uplink, reboot the Pi. Everything must come up from the persisted secrets and the cached images (`restart: unless-stopped`); `sudo scripts/deploy.sh` without `--offline` must fail
in its first step, the `git fetch` (exit 128 and a raw git network error, because the uplink is down; the secret fetch is never reached), and leave the running stack alone (no docker call is made); `sudo scripts/deploy.sh --offline` starts from the last-good secrets. Note: `--offline` skips the git fetch but
still verifies the signature of the checked-out commit. A certificate that expired meanwhile only shows in `cert-expiry.sh` and the daily timer (check `systemctl --failed`).

## 10. Disposing of or handing on a Pi or SD card (SEC-L4)

The SD card holds, unencrypted, both Roles Anywhere private keys, `/apps/secrets` (every secret in clear), the Authentik database (password hashes, TOTP seeds, WebAuthn
credentials) and the Tailscale node key. Before it leaves your hands: do section 1 (revoke) first, then wipe: `sudo shred -v -n 1 /dev/<device>` (or the card reader's secure erase, or
physical destruction for a failed card). Removing the node from Tailscale and revoking the generation matters more than the wipe, because a failed card cannot be wiped. Revocation is
coarse by design (bump `pki_generation`, or disable the trust anchor, which stops both identities); a CRL per certificate was considered and not built: for two certificates and one owner the
generation bump is the simpler, tested path, and 365 day certificates bound the exposure of an unnoticed theft.

## Drill checklist

Run this at every drill (at least once a year, and once before the first real certificate renewal), then add one row to the log below. A drill without all the lines is partial; say which line was skipped.

1. **Tabletop or spare-card walk through** of sections 0 to 8 (plan Q20): what would you do, in what order, with which secret from which place?
2. **CA restore test** (K5): restore the offline CA from BOTH copies (password manager attachment and USB stick) into scratch directories and run `scripts/pki/test-ca-restore.sh --ca-dir <dir>` on each (`ca-backup.md` section 3). Without a stick yet, test copy A and write "copy B: none yet" in the log.
   Record PASS or FAIL per copy, whether the copy's `issued.tsv` checksum matched the live one, and the CA certificate's expiry date. Refresh the copies if `issued.tsv` is stale.
3. **Authentik restore test** (K5): choose a dump by S3 `LastModified` and `VersionId` (`authentik-backup.md` sections 3 and 4), check that every key has exactly one version, restore it into a throwaway container with `--network none` and look at the users (section 5).
   Record the dump `LastModified` and `VersionId`, the user counts and the time it took. Check that `sudo scripts/preflight.sh --stage full` shows `backup-last` PASS, and run the monthly size and object count check.
4. **Timed real restore** (QA L-7, once, on a spare SD card or a spare Pi, or before the Pi is trusted with real users): run the whole of `authentik-backup.md` section 6 (the one-off key, the presigned URL, the stop and start of server and worker, the healthcheck wait and a login with the MFA device) and write down the minutes each part took and any step that did not work as written. The throwaway test cannot prove this path.
5. **Offline boot drill** (section 9), when a Pi can be unplugged safely.

## Drill log

| Date | Kind (tabletop, spare SD, real) | Who | CA restore test (PASS or FAIL; copy A, copy B) | Authentik restore test (dump time and version, users live vs restored, minutes) | Timed real restore (minutes, problems) | Result and notes |
|------|---------------------------------|-----|------------------------------------------------|---------------------------------------------------------------------------------|----------------------------------------|------------------|
| 2026-11-10 | Restore test only (first backup) | Owner, Claude | Not run yet (copy A pending; copy B: none yet, K5-B) | Dump of 2026-11-09 20:09 UTC, one version, key time within 7 s of `LastModified`. Restored into `--network none` throwaway (same image and digest): users 3 live / 3 restored, applications 2 / 2, 230 tables, authenticator tables and TOTP device present. About 10 minutes once the key was fed from the clipboard | Not run (L-7) | PASS for the Authentik backup. Partial drill. Lesson: on Windows Git Bash, `age -i -` from the keyboard never sees end of input (Ctrl-D and Ctrl-Z ignored); feed the key from `/dev/clipboard` instead, and paste the command before copying the key |
