# Runbook: Pi recovery (plan section 11.3, QA review gap)

Audience: the owner. For a dead SD card or SSD, a replaced Pi, or a lost or stolen Pi. Placeholders only; real values come from the password manager, the HCP workspace and the
bootstrap outputs. Exercise it as a drill (plan Q20, Q24) and record the date at the end of this file.

What survives: AWS (Route 53, SSM secrets, the identity stack), GitHub, the offline CA (laptop and its encrypted backup), the password manager. What is lost with the SD card:
`/etc/home-lab` (aws.env, the two private keys and certificates), `/apps` (Let's Encrypt state, Tailscale node key, Authentik database), the checkout.

## 0. Decide: replaced Pi, or lost or stolen Pi?

- **Lost or stolen (the SD card may be in someone else's hands):** the stolen keys can still call AWS until revoked. Revoke FIRST (section 1), then rebuild.
- **Dead card, you still hold it or it is destroyed:** you may skip revocation and reuse the generation, but revoking is cheap, so prefer it when in doubt.

## 1. Revoke the old identity [Owner, laptop, only for a lost or stolen Pi]

Fastest first (minutes), then the tidy version:

1. Disable the trust anchor so no certificate works: `aws rolesanywhere disable-trust-anchor --trust-anchor-id <uuid> --region af-south-1` (admin SSO), or set `enabled = false` on
   `aws_rolesanywhere_trust_anchor.ca` in `terraform/bootstrap` and apply. This stops BOTH identities (secret fetch and ACME) until you re-enable it in step 3.
2. In the Tailscale admin console, remove the old `homelab-pi` node and (if the node key could have leaked) expire it.
3. Treat every secret as exposed: rotate them as you can afford (`set-secret.sh`; the Authentik secret key rotation invalidates sessions, the Postgres password is changed in the database first (`\password authentik` in psql, which runs `ALTER USER`
   without the value in argv; see `rotate-secrets.md`). The break-glass password should be changed (`htpasswd -nBi -C 12 admin`).
4. Tidy revocation: bump `pki_generation` (for example `gen-2`) in `terraform/bootstrap/terraform.tfvars` and apply with admin SSO. The roles' trust policy pins the OU, so old certificates
   stop working for good; re-enable the trust anchor. (Cost: both new certificates must carry `OU=gen-2`.)

## 2. Prepare the new Pi [Pi]

1. Flash Raspberry Pi OS 64-bit, enable Raspberry Pi Connect, and give it the same DHCP reservation (or a new one: update the router, the Tailscale node address is new anyway).
2. Follow `m2-pi-setup.md` sections 0 to 3: Docker (login user NOT in the docker group), the root-owned checkout in `/opt/home-lab` with a deploy key, `preflight.sh`, `bootstrap.sh`.
3. Install `/etc/home-lab/allowed_signers` and check the checkout ownership and `sudo -l` (`m2-pi-setup.md` 3.1) so deploys verify; do this BEFORE the first `deploy.sh`.

## 3. New keys and certificates [Pi, then Laptop, then Pi]

1. On the Pi: `sudo scripts/pki/pi-csr.sh` (new keys; add `--generation gen-2` style flags exactly as in `m2-pi-setup.md` step 5).
2. On the laptop, with the offline CA from its encrypted backup (restore it first if the laptop was also lost, and test it): sign both CSRs (`scripts/pki/sign.sh`, step 6).
3. On the Pi: `sudo scripts/pki/pi-install-cert.sh traefik ...` and `host ...` (step 7). The installer refuses a certificate that is not valid yet: fix the clock first (`timedatectl`).
4. If you disabled the trust anchor in section 1, re-enable it now (`aws rolesanywhere enable-trust-anchor ...`).

## 4. `aws.env` and secrets [Laptop, then Pi]

1. Laptop: `scripts/render-aws-env.sh --generation <gen>` (reads the bootstrap outputs); paste the five lines into `/etc/home-lab/aws.env` (root 0600) as in step 10.
2. Pi: `sudo scripts/deploy.sh`. It verifies the signed commit, restores every secret from SSM (`fetch-secrets.sh`), and starts the stack. If SSM is unavailable, the password manager is the
   offline backup: use `scripts/set-secret.sh` from the laptop once AWS is back, or boot with `--offline` only if you restored the secrets directory yourself.

## 5. Tailscale [Laptop, Pi]

New one-off key: Tailscale console (tag `tag:homelab`, one-off, expires in a day), `scripts/set-secret.sh tailscale/auth-key`, `sudo scripts/deploy.sh --recreate tailscale`, check `status`,
then `scripts/set-secret.sh --unset tailscale/auth-key` and `sudo scripts/deploy.sh --recreate tailscale` (the secret file is replaced, the container only changes when recreated). Remove the old node in the admin console. The tailnet address changes: update the edge variable
`pi_tailnet_ipv4` and apply `terraform/edge` (the wildcard A record).

## 6. Authentik

The database lives on the card: **users and MFA devices are gone** until backups exist (a later phase). The blueprint rebuilds groups, providers, applications and the MFA policy.
Set `authentik/bootstrap-password` (`set-secret.sh`), `sudo scripts/deploy.sh --recreate authentik`, log in as `akadmin`, create your named admin, enrol MFA, deactivate `akadmin` again, set the bootstrap password back to UNSET
(`m4-authentik.md` section 8, then `sudo scripts/deploy.sh --recreate authentik` again). Re-create the family accounts and re-enrol their MFA.

## 7. Let's Encrypt certificate

The ACME storage is gone: Traefik requests a fresh wildcard certificate on first start (DNS-01 through the DNS-01 role). On production, mind the Let's Encrypt rate limits (5 duplicate
certificates per week): if you rebuild repeatedly while testing, switch `ACME_ENV` to staging first (`config/lab.env`).

## 8. Verify

`sudo scripts/preflight.sh --stage full`, `sudo scripts/s17-identity-tests.sh`, `sudo scripts/cert-expiry.sh`, browse `traefik.<domain>` and `dashboard.<domain>`, and
`sudo scripts/breakglass.sh on 10` then `off`. Then record the drill below.

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

## Drill log

| Date | Kind (tabletop, spare SD, real) | Who | Result and notes |
|------|---------------------------------|-----|------------------|
| (not run yet) | | | |
