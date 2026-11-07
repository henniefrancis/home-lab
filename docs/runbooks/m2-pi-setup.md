# Runbook: M2 Pi setup (preflight, bootstrap, PKI, aws.env, first secret fetch, Tailscale)

Plan: `docs/plan/phase-1-traefik.md` rev 7 (sections 6.5, 6.8, 6.10, U5-U9c, U12, U13). Milestone M2 is done when every step below has
passed and the final checks in section "Verify" are green.

Every step is tagged with who runs it:

| Tag | Meaning |
|-----|---------|
| **[Pi]** | the owner, in the Raspberry Pi Connect remote shell (or SSH), in the repo checkout `/opt/home-lab` |
| **[Laptop]** | the owner, on the Windows laptop in Git Bash or WSL, in the repo checkout |
| **[HCP]** | the owner, in the HCP Terraform web UI |
| **[Lead]** | the lead plans and applies Terraform and sets workspace variables; the owner waits for the go-ahead |

Rules for the whole runbook:
- Never paste a secret value, the CA passphrase or any `*.key` file into a chat or an agent. CSRs, certificates and the CA certificate
  are public and safe to paste. Scripts here never print keys or secret values.
- No real domain, account ID, ARN or IP address goes into git. `aws.env` and the tailnet IP stay on the Pi and in HCP variables.
- Run `sudo` only where shown.

## Order at a glance

| # | Who | What |
|---|-----|------|
| 0 | Pi | Prerequisites: 64-bit OS, SSD, Docker, router DHCP reservation, repo clone |
| 1 | Pi | `preflight.sh` |
| 2 | Pi | Fix the findings |
| 3 | Pi | `bootstrap.sh`, then `preflight.sh --stage bootstrap` |
| 4 | Laptop | Create the offline CA |
| 5 | Pi | Generate the two keys and CSRs |
| 6 | Laptop | Sign both CSRs |
| 7 | Pi | Install both certificates |
| 8 | HCP | Set `ca_cert_pem` |
| 9 | Lead | Plan and apply Roles Anywhere (and the `ra-*` config parameters) |
| 10 | Laptop and Pi | Write `/etc/home-lab/aws.env` (U13) |
| 11 | Laptop | Set the required secrets (U12) |
| 12 | Laptop | Tailscale console: policy, tag, one-off auth key; store the key (U8) |
| 13 | Pi | `fetch-secrets.sh` |
| 14 | Pi | Start Tailscale, report the tailnet IP |
| 15 | Laptop | Set the Tailscale key back to UNSET |
| 16 | Lead | Set `pi_tailnet_ipv4`, plan and apply the wildcard record |
| 17 | Pi | Verify (preflight full, S17 identity tests, S19 permissions) |

Steps 4 to 8 do not depend on steps 1 to 3 finishing, so the CA can be created while the Pi is being prepared.

---

## 0. Prerequisites [Pi]

The Pi is headless: everything below is typed in its terminal (Raspberry Pi Connect remote shell, or SSH). Paste one block at a time.

### 0.1 What is on the Pi now (read-only)

```bash
grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' /etc/os-release
uname -m; dpkg --print-architecture
tr -d '\0' < /proc/device-tree/model; echo
findmnt -no SOURCE /
docker version --format 'docker engine {{.Server.Version}}' 2>&1 | tail -1
docker compose version 2>&1
dpkg -l | awk '/docker|containerd/ {print $2, $3}'
ip -4 -br addr | grep -v '^lo'
ip route show default
nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>&1
```

You need: `aarch64` and `arm64` (64-bit kernel and userland), Debian 12 `bookworm` or 13 `trixie`, Docker from Docker's own
repository (`docker-ce`, not Debian's `docker.io`), and Compose 2.20 or newer. `findmnt` shows `/dev/mmcblk0p2` for an SD card or
`/dev/sda2` for a USB SSD (the preflight WARNs on an SD card: Docker, Postgres and logs wear them out).

### 0.2 Update the OS

```bash
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update            # shows bootloader firmware; add -a to stage an update if one is offered
sudo reboot
```

If apt says `dpkg was interrupted`, run `sudo dpkg --configure -a` first, then the block again. If it warns that Docker's repository is
"configured multiple times" in `docker.list` and `docker.sources`, remove the old one: `sudo rm /etc/apt/sources.list.d/docker.list`.

This brings every package to the latest release **within** your Debian version. Moving from bookworm to trixie is a major upgrade:
Raspberry Pi recommend a fresh install of the new image rather than an in-place upgrade. Phase 1 starts with an empty `/apps`, so a
reflash (Raspberry Pi Imager, "Raspberry Pi OS Lite (64-bit)", enable SSH and set the user in its settings) is the clean path if you want
trixie. Bookworm is supported and fine for this build.

### 0.3 Docker Engine and Compose from Docker's repository

If 0.1 listed `docker-ce` from Docker's repository, the `full-upgrade` above already updated it: just re-check `docker compose version`.
If it listed `docker.io`, `docker-compose` or `podman-docker` (Debian's packages), or nothing, install Docker's own packages
(https://docs.docker.com/engine/install/debian/):

```bash
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove -y "$pkg"; done
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo rm -f /etc/apt/sources.list.d/docker.list   # old one-line format; two entries make apt warn "configured multiple times"
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # log out and back in (or reboot) for this to take effect
```

Removing Debian's packages keeps images and volumes in `/var/lib/docker`. Check afterwards:

```bash
docker version --format '{{.Server.Version}}'; docker compose version; docker run --rm hello-world
```

### 0.4 A fixed LAN address (U5)

The Pi needs an address that never changes, inside `10.0.0.0/24`. Two ways; pick one.

**A. Router DHCP reservation (preferred).** In your router's admin page (from the laptop's browser, usually `http://10.0.0.1`), find
"DHCP reservation", "Static lease" or "Address reservation" and bind the Pi's MAC address to its current IP. The router then never gives
that address to anything else. The Pi's MAC:

```bash
ip -br link | grep -E '^(eth0|wlan0)'
```

**B. Static address on the Pi (when the router has no reservation option).** Raspberry Pi OS bookworm and later use NetworkManager.
Pick an address **outside** the router's DHCP pool (check the pool range in the router; `10.0.0.50` below is an example), and use the
gateway shown by `ip route show default`:

```bash
CON=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: '$2=="eth0"||$2=="wlan0"{print $1; exit}')
echo "connection: $CON"
sudo nmcli connection modify "$CON" ipv4.method manual ipv4.addresses 10.0.0.50/24 ipv4.gateway 10.0.0.1 ipv4.dns "10.0.0.1 1.1.1.1"
sudo nmcli connection up "$CON"
```

The terminal may freeze for a few seconds while the address changes; Raspberry Pi Connect reconnects through its relay. To undo:
`sudo nmcli connection modify "$CON" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns "" && sudo nmcli connection up "$CON"`.

### 0.5 Clone the repo

Clone to `/opt/home-lab` (the repo is private until the end of M6, so the Pi needs read access). One option is a read-only
deploy key:

On the Pi:

```bash
sudo apt-get install -y git
ssh-keygen -t ed25519 -N '' -C home-lab-pi-deploy -f ~/.ssh/home-lab-deploy
cat ~/.ssh/home-lab-deploy.pub        # the PUBLIC key: one line starting with ssh-ed25519
```

On the laptop, register that public line as a **read-only** deploy key (or GitHub web UI: repo Settings, Deploy keys, "Allow write
access" unticked):

```bash
gh repo deploy-key add - --repo <owner>/home-lab --title home-lab-pi <<< 'ssh-ed25519 AAAA... home-lab-pi-deploy'
```

Back on the Pi:

```bash
sudo mkdir -p /opt/home-lab && sudo chown "$USER": /opt/home-lab
GIT_SSH_COMMAND='ssh -i ~/.ssh/home-lab-deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
  git clone git@github.com:<owner>/home-lab.git /opt/home-lab
git -C /opt/home-lab config core.sshCommand 'ssh -i ~/.ssh/home-lab-deploy -o IdentitiesOnly=yes'
```

The deploy key is a credential on the Pi's disk: it is read-only, repo-scoped and revocable in GitHub. After M6 (public repo) it is not
needed.

All Pi commands below run from `cd /opt/home-lab`.

## 1. Preflight [Pi]

```bash
cd /opt/home-lab
scripts/preflight.sh
```

It changes nothing. It checks: 64-bit kernel and userland, OS release, boot device (SD vs SSD), memory cgroup, Docker Engine and Compose,
LAN IP and reservation, SSH state, free disk on `/`, time sync, and outbound HTTPS to AWS, Tailscale, Let's Encrypt staging, Docker Hub,
GHCR and GitHub. It ends with `Summary: N PASS, N WARN, N FAIL`. WARNs are decisions for you; any FAIL blocks `bootstrap.sh`.

## 2. Fix the findings [Pi]

| Finding | Fix |
|---------|-----|
| `arch` FAIL | Reflash Raspberry Pi OS (64-bit). A 32-bit userland cannot run the pinned arm64 binaries. |
| `memory-cgroup` FAIL | Append `cgroup_memory=1 cgroup_enable=memory` to the single line of `/boot/firmware/cmdline.txt` (`/boot/cmdline.txt` on older images) unless already there, then reboot: `sudo sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt && sudo reboot`. Do not add a new line; the file must stay one line. |
| `docker` / `compose` FAIL | Install from Docker's apt repo (step 0). |
| `time-sync` FAIL | `sudo timedatectl set-ntp true`. IAM Roles Anywhere rejects requests with a skewed clock. |
| `lan-ip` FAIL | The Pi is outside `LAN_CIDR` (config/lab.env). Fix the network, not the config. |
| `ip-reservation` WARN | Create the DHCP reservation in the router (U5) using the MAC the line prints. |
| `boot-device` WARN | Move to a USB SSD when convenient (plan R5). Not blocking. |
| `ssh` WARN (password auth on) | Switch to key-only SSH, or keep SSH off and use Pi Connect (A4). |
| `https:*` FAIL | A firewall or DNS problem between the Pi and the named host. |

Re-run `scripts/preflight.sh` until there is no FAIL.

## 3. Bootstrap [Pi]

```bash
sudo scripts/bootstrap.sh
sudo scripts/preflight.sh --stage bootstrap
```

`bootstrap.sh` is idempotent. It refuses to run while the preflight has a FAIL, then:

1. installs missing packages (`curl unzip gnupg jq openssl git`);
2. creates `/apps/{traefik,authentik,homepage,tailscale}` (root 0755; `traefik/letsencrypt` and `tailscale/state` 0700), `/apps/.secrets.d` and
   `/apps/secrets` (0700 root), `/etc/home-lab` and `/etc/home-lab/pki` (0700 root);
3. creates the Docker networks `proxy` (bridge, subnet `PROXY_SUBNET`), `socket-proxy` (internal) and `authentik-internal` (internal);
4. loads the `tun` module and persists it in `/etc/modules-load.d/home-lab.conf`;
5. installs **AWS CLI v2** (aarch64): downloads the official installer and its detached signature, imports the AWS CLI team key from
   `scripts/pubkeys/awscli-team.asc`, requires fingerprint `FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C`, and installs only if gpg reports a
   valid signature by exactly that key;
6. installs **`aws_signing_helper` 1.8.6** (aarch64) to `/usr/local/bin` (root, 0555) after a SHA256 check against the value in the AWS user guide;
7. records the installed versions in `/etc/home-lab/installed-versions`.

Where the pins come from (also written in `scripts/lib/pins.sh`):
- helper download URL and SHA256: https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html (Linux, Aarch64 row);
- AWS CLI key and fingerprint: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html. The key expires 2027-07-01; after that
  update `scripts/pubkeys/awscli-team.asc` and `AWSCLI_KEY_FPR` from that page.

The stage `bootstrap` preflight confirms the tools, the directory modes, the Docker networks and the `tun` module.

## 4. Create the offline CA [Laptop]

Run this on the laptop only. The CA key never goes to the Pi, git or any chat.

```bash
cd /path/to/home-lab-new
scripts/pki/new-ca.sh --out "$HOME/home-lab-ca"
```

- Generate a strong passphrase in the password manager first. `openssl` asks for it twice when creating the key and once more to sign the CA
  certificate. The script never shows or stores it.
- Result: `~/home-lab-ca/ca.key` (ECDSA P-384, AES-256 encrypted) and `~/home-lab-ca/ca.crt` (`CN=home-lab-offline-ca`, 5 years, `CA:TRUE`, pathlen 0).
- The script refuses to run inside a git work tree and refuses to overwrite an existing CA.
- **Store `ca.key` (attach the file) and its passphrase in the password manager.** Keep `ca.key` only on encrypted storage. Only `ca.crt` is public.
- The script prints `ca.crt` at the end; the SHA-256 fingerprint is printed too. Note it for step 8.

## 5. Generate keys and CSRs on the Pi [Pi]

```bash
sudo scripts/pki/pi-csr.sh --generation gen-1
```

`--generation` must equal the HCP variable `pki_generation` (default `gen-1`). The script creates two P-256 keys under `/etc/home-lab/pki/`:

| Identity | Key file | Owner and mode | Subject | Used by |
|----------|----------|----------------|---------|---------|
| Traefik ACME (DNS-01) | `traefik.key` | `10001:10001` 0400 | `CN=home-lab-pi-traefik, OU=gen-1` | only the ra-helper container (M3), role `home-lab-traefik-dns01` |
| Pi host (secret fetch) | `host.key` | `root:root` 0400 | `CN=home-lab-pi-host, OU=gen-1` | the host only, role `home-lab-pi-host`; never mounted into a container |

The keys are generated on the Pi and never leave it. The script prints the two CSRs (public data) between `===== name.csr =====` markers.
If a key already exists it is reused (a renewal); `--rotate-keys` replaces it.

## 6. Sign both CSRs [Laptop]

Copy each CSR from the Pi Connect terminal (select, copy) and paste it into a file on the laptop with a here-document. Paste the whole block from
`-----BEGIN CERTIFICATE REQUEST-----` to `-----END CERTIFICATE REQUEST-----`, then type `EOF` on its own line:

```bash
mkdir -p ~/m2-pki && cd ~/m2-pki
cat > host.csr <<'EOF'
(paste the host CSR here)
EOF
cat > traefik.csr <<'EOF'
(paste the traefik CSR here)
EOF

cd /path/to/home-lab-new
scripts/pki/sign.sh --ca-dir "$HOME/home-lab-ca" --role host    --csr ~/m2-pki/host.csr    --out ~/m2-pki/host.crt    --generation gen-1
scripts/pki/sign.sh --ca-dir "$HOME/home-lab-ca" --role traefik --csr ~/m2-pki/traefik.csr --out ~/m2-pki/traefik.crt --generation gen-1
```

`sign.sh` asks for the CA passphrase and **refuses** unless the CSR has a valid self-signature, an ECDSA P-256 key and exactly the expected subject
(`CN=home-lab-pi-host` or `CN=home-lab-pi-traefik`, plus `OU=<generation>`, nothing else). Certificates are `CA:FALSE`, `digitalSignature`, `clientAuth`,
SHA-256, **365 days**, with a random serial, and are chain-verified before they are written. Each issuance is logged in `~/home-lab-ca/issued.tsv`.

## 7. Install the certificates on the Pi [Pi]

Paste each certificate into a temporary file and install it (`cat ~/m2-pki/host.crt` on the laptop to copy it):

```bash
cat > /tmp/host.crt <<'EOF'
(paste the host certificate here)
EOF
sudo scripts/pki/pi-install-cert.sh host /tmp/host.crt --generation gen-1

cat > /tmp/traefik.crt <<'EOF'
(paste the traefik certificate here)
EOF
sudo scripts/pki/pi-install-cert.sh traefik /tmp/traefik.crt --generation gen-1
rm -f /tmp/host.crt /tmp/traefik.crt
```

The installer refuses unless the subject, issuer (`CN=home-lab-offline-ca`), `CA:FALSE`, `digitalSignature`, validity and **the public key matching the
Pi's own key** are all right, and it refuses input that contains a private key. It writes `/etc/home-lab/pki/{host,traefik}.crt` as root 0444.

## 8. Give Terraform the CA certificate [HCP]

In the HCP Terraform workspace `home-lab`, set the **terraform** variable `ca_cert_pem` (not sensitive; it is a public certificate) to the full PEM of
`~/home-lab-ca/ca.crt`, including the BEGIN and END lines. Confirm `pki_generation` is unset (default `gen-1`) or equals the generation used above.
Tell the lead it is done and give the CA certificate's SHA-256 fingerprint (from step 4) so the lead can confirm the trust anchor matches. Do not add
`pi_tailnet_ipv4` yet.

## 9. Roles Anywhere apply [Lead]

The lead runs a remote plan and, after the owner approves, an apply for `terraform/edge`. With `ca_cert_pem` set, Terraform creates:
the trust anchor `home-lab-offline-ca`, profiles `home-lab-traefik` and `home-lab-pi-host`, roles `home-lab-traefik-dns01` and `home-lab-pi-host`
(trust pinned to the cert CN, the `pki_generation` OU and issuer `home-lab-offline-ca`), and the three `config/ra-*` String parameters in SSM. Expected
plan: additions only, nothing destroyed or replaced. The lead tells the owner when the outputs exist.

## 10. Write `/etc/home-lab/aws.env` (U13) [Laptop, then Pi]

On the laptop, print the file contents from the Terraform outputs (needs `terraform login` and `TF_CLOUD_ORGANIZATION`; see
`docs/runbooks/hcp-terraform-bootstrap.md`; run `terraform -chdir=terraform/edge init` once if you have not):

```bash
scripts/render-aws-env.sh --generation gen-1
```

It prints five lines (`AWS_REGION`, `PKI_GENERATION`, `RA_TRUST_ANCHOR_ARN`, `RA_HOST_PROFILE_ARN`, `RA_HOST_ROLE_ARN`). They identify the AWS account, so they
are only for the Pi. Copy them, then on the Pi:

```bash
sudo install -m 0600 -o root -g root /dev/null /etc/home-lab/aws.env
sudo tee /etc/home-lab/aws.env > /dev/null <<'EOF'
(paste the five lines here)
EOF
sudo stat -c '%U:%G %a %n' /etc/home-lab/aws.env      # expect: root:root 600 /etc/home-lab/aws.env
```

## 11. Set the required secrets (U12) [Laptop]

`fetch-secrets.sh` **fails closed**: it refuses to publish anything while a required parameter still holds the `UNSET-` placeholder. The required ones are
`authentik/secret-key`, `authentik/postgres-password` and `traefik/breakglass-htpasswd`. If you have not done U12 yet, do it now as described in
`docs/runbooks/secrets-ssm.md` (generate each value in the password manager first):

```bash
aws sso login --profile henniefrancis
scripts/set-secret.sh authentik/secret-key          # 60+ characters
scripts/set-secret.sh authentik/postgres-password   # under 99 characters
scripts/set-secret.sh traefik/breakglass-htpasswd   # a bcrypt htpasswd line, see below
```

To make the htpasswd line without putting the password in argv or history (the password manager keeps the plaintext):

```bash
docker run --rm -i httpd:2.4-alpine htpasswd -nBi admin
```

Type the password and press Enter; paste the printed `admin:$2y$...` line into the `set-secret.sh` prompt. Optional parameters
(`authentik/bootstrap-password`, `homepage/authentik-token`) can stay UNSET for now.

## 12. Tailscale console: policy, tag and auth key (U8) [Laptop]

The Tailscale admin console is a SaaS outside AWS, so the Terraform-only rule (which covers AWS) does not apply; the committed
`tailscale/policy.example.hujson` is the reviewable source and you paste it by hand. This is a documented manual exception, like `set-secret.sh`.

1. Open https://login.tailscale.com/admin/acls/file. **Merge** the `tagOwners` entry `tag:homelab` and the one `acls` rule from
   `tailscale/policy.example.hujson` into the existing policy (do not blindly replace it), then save. The rule lets tailnet members reach the Pi on
   ports 80 and 443 only; nothing lets the Pi connect out.
2. Open Settings, Keys (https://login.tailscale.com/admin/settings/keys), Generate auth key:
   - Reusable: **off**; Ephemeral: **off**; Pre-approved: **on** if your tailnet has device approval; Tags: **`tag:homelab`**; Expiration: **1 day**.
3. Copy the key (`tskey-auth-...`) into the password manager, then store it in SSM (the prompt does not echo):

   ```bash
   scripts/set-secret.sh tailscale/auth-key
   ```

   No subnet router, no exit node and no DNS override are configured (plan 6.5).

## 13. First secret fetch [Pi]

```bash
sudo scripts/fetch-secrets.sh --dry-run     # checks AWS access, types and placeholders; publishes nothing
sudo scripts/fetch-secrets.sh
sudo ls -lR /apps/secrets/ | grep -v '^total'   # names, owners and modes only; never cat these files
```

What it does: writes `/etc/home-lab/aws-config` (root 0600) with a `credential_process` profile that runs `aws_signing_helper credential-process` with the
**host** certificate and key; calls `ssm get-parameters-by-path /home-lab --recursive --with-decryption` once; maps every parameter with
`config/secrets-manifest.tsv`; builds a release under `/apps/.secrets.d/` (staging dir removed on any exit), then **atomically** repoints the symlink
`/apps/secrets` at it. Expected result:

| File | Owner and mode | Content |
|------|----------------|---------|
| `authentik/secret-key`, `authentik/postgres-password` | `1000:1000` 0400 | the secrets |
| `traefik/breakglass-htpasswd` | `0:0` 0400 | the htpasswd line |
| `tailscale/tailscale.env` | `0:0` 0600 | `TS_AUTHKEY=...` (empty file once the parameter is UNSET) |
| `runtime.env` | `0:0` 0600 | `DOMAIN`, `ROUTE53_ZONE_ID`, `RA_TRUST_ANCHOR_ARN`, `RA_ACME_PROFILE_ARN`, `RA_ACME_ROLE_ARN` |
| optional files | | omitted while their parameter is UNSET |

Exit codes: 3 = AWS unreachable or access denied (existing secrets untouched), 4 = validation failed (a required parameter is UNSET, missing or the wrong type).

## 14. Start Tailscale [Pi]

```bash
sudo scripts/deploy.sh --only tailscale
docker logs --tail 30 tailscale
docker exec tailscale tailscale --socket=/tmp/tailscaled.sock status
docker exec tailscale tailscale --socket=/tmp/tailscaled.sock ip -4
```

`deploy.sh --only tailscale` pulls the repo (`git pull --ff-only`), refreshes the secrets, then runs
`docker compose -f tailscale/compose.yaml --env-file config/lab.env --env-file /apps/secrets/runtime.env up -d`. The container uses host networking, state in
`/apps/tailscale/state`, `tag:homelab`, `TS_AUTH_ONCE=true`. If the `--socket` path is rejected, drop the flag (the image default socket differs between
releases). Look for `Running` and a `100.x.y.z` address. In the Tailscale admin console the machine `homelab-pi` should appear tagged `tag:homelab`.

**Report the tailnet IPv4 (`100.x.y.z`) to the lead.** Do not commit it or paste it anywhere else.

## 15. Remove the auth key from SSM [Laptop]

The node has joined, so the key is no longer needed (it was one-off and expires in a day anyway):

```bash
scripts/set-secret.sh --unset tailscale/auth-key
```

Then on the Pi refresh the secrets and confirm Tailscale stays connected without a key:

```bash
sudo scripts/fetch-secrets.sh                  # tailscale.env becomes an empty file ("empty" in the manifest)
sudo docker restart tailscale && sleep 10
docker exec tailscale tailscale --socket=/tmp/tailscaled.sock status | head -3
```

## 16. Wildcard record [Lead]

The lead sets the `pi_tailnet_ipv4` workspace variable to the reported address, runs a plan (expected: one `*` A record added; the `www` TXT placeholder keeps
`www` out of the wildcard, and the Microsoft 365 records are untouched), and applies after the owner approves.

## 17. Verify [Pi]

```bash
sudo scripts/preflight.sh --stage full      # tools, directories, aws.env, key and cert owners/modes/subjects, repo hygiene, cert expiry
sudo scripts/s17-identity-tests.sh          # S17: identity isolation (outcomes only)
sudo scripts/cert-expiry.sh
```

`s17-identity-tests.sh` proves, with real session credentials:
- **pi-host role**: reading `/home-lab/authentik/secret-key` (with decryption) works; `/not-home-lab/x` is **AccessDenied** (not ParameterNotFound);
  `PutParameter` is denied; `route53:ListHostedZones` is denied; calling `kms:Decrypt` directly is denied.
- **ACME role**: SSM and direct `kms:Decrypt` are denied; it can list records in the zone; changing any non-`_acme-challenge` record is denied (probed with a DELETE of
  a name that does not exist, so a bad policy cannot create anything).
- **Mounts**: no running container mounts the host key; the traefik key is mounted at most in `ra-helper`.

Manual checks for S19 and Q18:

```bash
sudo stat -c '%U:%G %a %n' /apps/.secrets.d /etc/home-lab /etc/home-lab/pki /etc/home-lab/pki/*.key /etc/home-lab/aws.env /etc/home-lab/aws-config
sudo stat -L -c '%U:%G %a %n' /apps/secrets          # expect root:root 700
sudo find /apps/.secrets.d -maxdepth 1 -name '.staging-*'   # expect no output (no staging dir left behind)
git -C /opt/home-lab status --ignored --short        # expect nothing secret-looking
```

Expected: `host.key` root:root 400, `traefik.key` 10001:10001 400, `/etc/home-lab`, `/etc/home-lab/pki`, `/apps/.secrets.d` and `/apps/secrets` 700 root, `aws.env` and `aws-config` 600.

**Revocation test (manual, with the lead):** the lead bumps `pki_generation` to `gen-2` in a test apply; on the Pi `sudo scripts/fetch-secrets.sh --dry-run` must now fail with
exit 3 (the old certificates no longer match the trust policy); the lead reverts to `gen-1` and confirms the fetch works again. Automated placeholder, interruption and
no-leak checks for `fetch-secrets.sh` run in CI (`scripts/test-fetch-secrets.sh`).

## Renewal and maintenance

- Certificates last 365 days. `scripts/cert-expiry.sh` (also run by `deploy.sh` and the full preflight) WARNs under 30 days. To renew, repeat steps 5 to 7: `pi-csr.sh` reuses the
  existing keys, you sign on the laptop and install. After a lost or stolen Pi: reissue with a new generation (bump `pki_generation`, use `--generation gen-2` in
  steps 5 to 7, write `PKI_GENERATION=gen-2` into `aws.env`).
- After any secret changes: `scripts/set-secret.sh <name>` on the laptop, `sudo scripts/deploy.sh` on the Pi, then recreate the consuming service
  (`docker compose ... up -d --force-recreate <service>`); files are replaced, not edited in place.
- `sudo scripts/deploy.sh --offline` starts from the last-good secrets when AWS or the internet is unavailable. Without `--offline` a failed fetch aborts the deploy.
- The AWS CLI GPG key in `scripts/pubkeys/awscli-team.asc` expires 2027-07-01.

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| `fetch-secrets.sh` exit 3, AWS says `AccessDeniedException` on `CreateSession` or similar | The certificate subject/OU does not match the trust policy, the CA in the trust anchor is not the one that signed the cert (compare fingerprints), or `PKI_GENERATION` and `pki_generation` differ. |
| exit 3 with a clock or signature error | Time sync (preflight `time-sync`). |
| exit 3 `AccessDenied` on `GetParametersByPath` | The pi-host policy needs the path-root ARN (`parameter/home-lab`); verify `iam-pi-host.tf` was applied. First real test of this is step 13. |
| exit 4 `still holds the UNSET placeholder` | Run `scripts/set-secret.sh <name>` for the named parameter (step 11). |
| exit 4 `type is String, expected SecureString` | The parameter was recreated outside Terraform; investigate before continuing. |
| Tailscale `invalid key` or the machine is not tagged | Key expired, was reusable/ephemeral, or lacks `tag:homelab`, or the tag is missing in `tagOwners`. Create a new key, `set-secret.sh tailscale/auth-key`, `deploy.sh --only tailscale`, then unset. |
| `docker: permission denied` | Run the script with `sudo`. |

## What was and was not verified when this runbook was written

Automated (laptop, WSL and CI): shellcheck, yamllint, `docker compose config`, the PKI flow with its refusal cases, `fetch-secrets.sh` against a mock `aws`, and the
preflight script's logic on a non-Pi host. **Only testable on the Pi, first run by the owner:** the real preflight findings, `bootstrap.sh` (apt, AWS CLI install,
helper download and checksum), `aws_signing_helper` credential-process against the real trust anchor, `GetParametersByPath` on the `/home-lab` path ARN, the Tailscale
container (`/dev/net/tun`, capabilities, `tailscale` CLI socket path) and the S17 results.
