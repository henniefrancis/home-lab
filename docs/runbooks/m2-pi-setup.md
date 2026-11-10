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
| 3a | Laptop and Pi | **Signed deploys (section 3.1): signing key, `allowed_signers`, root-owned checkout, no docker group. Do this before any `deploy.sh` (steps 14, M3, M4); every deploy is refused without it** |
| 4 | Laptop | Create the offline CA |
| 5 | Pi | Generate the two keys and CSRs |
| 6 | Laptop | Sign both CSRs |
| 7 | Pi | Install both certificates |
| 8 | Owner | Put `ca_cert_pem` into the gitignored `terraform/bootstrap/terraform.tfvars` |
| 9 | Owner (admin SSO) | `terraform apply` of `terraform/bootstrap`: the identity stack (trust anchor, profiles, the two lab roles, the KMS key). See `sec-remediation-apply-order.md` for the order when migrating from the old layout |
| 10 | Laptop and Pi | Write `/etc/home-lab/aws.env` (U13) |
| 11 | Laptop | Set the required secrets (U12) |
| 12 | Laptop | Tailscale console: policy, tag, one-off auth key; store the key (U8) |
| 13 | Pi | `fetch-secrets.sh` |
| 14 | Pi | Start Tailscale, report the tailnet IP |
| 15 | Laptop | Set the Tailscale key back to UNSET |
| 16 | Lead | Set `pi_tailnet_ipv4`, plan and apply the wildcard record |
| 17 | Pi | Verify (preflight full, S17 identity tests, S19 permissions) |

Steps 4 to 8 do not depend on steps 1 to 3 finishing, so the CA can be created while the Pi is being prepared. Step 3a is not optional and comes first: with no `allowed_signers` file `deploy.sh` refuses everything (NEW-7).

---

## 0. Prerequisites [Pi]

The Pi is headless: everything below is typed in its terminal (Raspberry Pi Connect remote shell, or SSH). Paste one block at a time.

### 0.1 What is on the Pi now (read-only)

```bash
grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' /etc/os-release
uname -m; dpkg --print-architecture
tr -d '\0' < /proc/device-tree/model; echo
findmnt -no SOURCE /
sudo docker version --format 'docker engine {{.Server.Version}}' 2>&1 | tail -1
sudo docker compose version 2>&1
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

If 0.1 listed `docker-ce` from Docker's repository, the `full-upgrade` above already updated it: just re-check `sudo docker compose version`.
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
# Do NOT add your login user to the docker group (SEC-M3): that group is root-equivalent (docker run -v /:/h ...), so it would
# undo the uid separation of the secret files. Use `sudo docker ...` everywhere on the Pi. If it is already the case:
#   sudo gpasswd -d "$USER" docker      (then log out and back in)
```

Removing Debian's packages keeps images and volumes in `/var/lib/docker`. Check afterwards:

```bash
sudo docker version --format '{{.Server.Version}}'; sudo docker compose version; sudo docker run --rm hello-world
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
# The checkout is owned by ROOT (SEC-M3): root runs its scripts, so nobody who can log in may be able to change a file in it.
# The deploy key therefore lives in root's home, not in the login user's.
sudo install -d -m 0700 /root/.ssh
sudo install -m 0600 -o root -g root ~/.ssh/home-lab-deploy /root/.ssh/home-lab-deploy
shred -u ~/.ssh/home-lab-deploy ~/.ssh/home-lab-deploy.pub 2> /dev/null || rm -f ~/.ssh/home-lab-deploy ~/.ssh/home-lab-deploy.pub
sudo mkdir -p /opt/home-lab
sudo GIT_SSH_COMMAND='ssh -i /root/.ssh/home-lab-deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
  git clone git@github.com:<owner>/home-lab.git /opt/home-lab
sudo git -C /opt/home-lab config core.sshCommand 'ssh -i /root/.ssh/home-lab-deploy -o IdentitiesOnly=yes'
sudo chown -R root:root /opt/home-lab
```

From here on, git commands on the Pi are `sudo git -C /opt/home-lab ...`; `sudo scripts/deploy.sh` does the pulling itself.

The deploy key is a credential on the Pi's disk: it is read-only, repo-scoped and revocable in GitHub. After M6 (public repo) it is not
needed.

All Pi commands below run from `cd /opt/home-lab` (read-only for you; use `sudo` for anything that changes it).

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
| `memory-cgroup` FAIL | Append `cgroup_memory=1 cgroup_enable=memory` to the single line of `/boot/firmware/cmdline.txt` (`/boot/cmdline.txt` on older images) unless already there, then reboot: `grep -q cgroup_memory=1 /boot/firmware/cmdline.txt || sudo sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt; sudo reboot` (the grep makes it safe to repeat: the flags are never appended twice). Do not add a new line; the file must stay one line. |
| `docker` / `compose` FAIL | Install from Docker's apt repo (step 0). |
| `time-sync` FAIL | `sudo timedatectl set-ntp true`. IAM Roles Anywhere rejects requests with a skewed clock. |
| `lan-ip` FAIL | The Pi is outside `LAN_CIDR` (config/lab.env). Fix the network, not the config. |
| `ip-reservation` WARN | Create the DHCP reservation in the router (U5) using the MAC the line prints. |
| `boot-device` WARN | Move to a USB SSD when convenient (plan R5). Not blocking. |
| `ssh` WARN (password auth on) | Switch to key-only SSH, or keep SSH off and use Pi Connect (A4). |
| `auto-updates` WARN (full stage) | `sudo scripts/bootstrap.sh`: installs `unattended-upgrades` and writes `/etc/apt/apt.conf.d/52home-lab-auto-upgrades` (daily Debian security updates, never an automatic reboot; Docker and Raspberry Pi archive updates stay manual) (H1). |
| `reboot-required` WARN (full stage) | An update (often the kernel) needs a reboot: `sudo reboot` at a quiet moment, then `sudo scripts/preflight.sh --stage full`. |
| `lan-services` WARN (full stage) | `sudo scripts/bootstrap.sh` stops and masks avahi (mDNS) and Bluetooth, which the lab does not use (H2). Undo: `sudo systemctl unmask <unit> && sudo systemctl enable --now <unit>`. |
| `https:*` FAIL | A firewall or DNS problem between the Pi and the named host. |

Re-run `scripts/preflight.sh` until there is no FAIL.

## 3. Bootstrap [Pi]

```bash
sudo scripts/bootstrap.sh
sudo scripts/preflight.sh --stage bootstrap
```

`bootstrap.sh` is idempotent. It refuses to run while the preflight has a FAIL, then:

1. installs missing packages (`curl unzip gnupg jq openssl git openssh-client util-linux`; `ssh-keygen` verifies commit signatures, `flock` serialises secret fetches);
2. creates `/apps/{traefik,authentik,homepage,tailscale}` (root 0755; `traefik/letsencrypt` and `tailscale/state` 0700), `/apps/.secrets.d` and
   `/apps/secrets` (0700 root), `/etc/home-lab` and `/etc/home-lab/pki` (0700 root); `/apps/traefik/dynamic` (root 0755, the watched copy of `traefik/dynamic`) and `/apps/traefik/letsencrypt` (0700, owned by the Traefik service id 10004: Traefik runs non-root);
3. creates the Docker networks `proxy` (bridge, subnet `PROXY_SUBNET`), `authentik-auth` (bridge, subnet `AUTHENTIK_AUTH_SUBNET`: shared by Traefik and `authentik-server` only) and `authentik-internal` (internal); there is no `socket-proxy` network any more (a leftover one is reported, remove it with `sudo docker network rm socket-proxy`);
4. loads the `tun` module and persists it in `/etc/modules-load.d/home-lab.conf`;
5. installs **AWS CLI v2** (aarch64): downloads the official installer and its detached signature, imports the AWS CLI team key from
   `scripts/pubkeys/awscli-team.asc`, requires fingerprint `FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C`, and installs only if gpg reports a
   valid signature by exactly that key;
6. installs **`aws_signing_helper` 1.8.6** (aarch64) to `/usr/local/bin` (root, 0555) after a SHA256 check against the value in the AWS user guide;
7. records the installed versions in `/etc/home-lab/installed-versions`;
8. installs and enables `home-lab-cert-expiry.timer` (daily certificate expiry check) and `home-lab-breakglass-reset.service` (removes the break-glass login at every boot), and makes the checkout root-owned if it is not (SEC-M3, QA-M-4, SEC-L3).

Where the pins come from (also written in `scripts/lib/pins.sh`):
- helper download URL and SHA256: https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html (Linux, Aarch64 row);
- AWS CLI key and fingerprint: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html. The key expires 2027-07-01; after that
  update `scripts/pubkeys/awscli-team.asc` and `AWSCLI_KEY_FPR` from that page.

The stage `bootstrap` preflight confirms the tools, the directory modes, the Docker networks and the `tun` module.

### 3.1 Who can reach root, and signed deploys [Laptop, then Pi] (SEC-M3, SEC-M7)

Do this section right after `bootstrap.sh` and before the first `deploy.sh`: with no `allowed_signers` file every deploy is refused.

**Login user, docker and the checkout.** `docker` group membership is root-equivalent, so the login user is not in it and uses `sudo docker`. The checkout is
root-owned and `deploy.sh` REFUSES to run unless the whole tree (`.git` included) is root-owned and not writable by others (NEW-1). Check and fix:

```bash
id -nG "$USER" | tr ' ' '\n' | grep -x docker && sudo gpasswd -d "$USER" docker   # then log out and in; no output means already clean
sudo find /opt/home-lab \( -not -user root -o \( -not -type l -a -perm /022 \) \) -print -quit   # expect NO output
# if it prints a path:  sudo chown -R root:root /opt/home-lab && sudo chmod -R go-w /opt/home-lab
```

The real boundary is the Raspberry Pi Connect account (a cloud-brokered shell) plus your sudo password (N4): turn on 2FA with a passkey or security key on the Raspberry
Pi ID, turn Pi Connect remote shell off when you do not need it, and confirm that sudo asks for a password. Raspberry Pi OS ships a `NOPASSWD` rule for the first user,
which would void everything in this section:

```bash
sudo -k; sudo -l                                                         # must ask for your password
sudo sh -c 'grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/'              # expect no output; if a file is listed: sudo visudo -f <that file>
```

**Signed deploys.** `scripts/deploy.sh` merges and runs only a commit whose SSH signature verifies against `/etc/home-lab/allowed_signers`, a file OUTSIDE the
checkout (so a pushed commit cannot change who is trusted). The file must be owned by root, in a root-owned directory, not writable by others and not a symlink. There is
no bypass flag; with no or a bad file it refuses. **The Pi is the only place signatures are enforced:** GitHub does not require signed commits (decision 2026-11-09).

On the laptop, once:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/home-lab-signing -C "home-lab commit signing"   # use a passphrase; or a hardware key: ssh-keygen -t ed25519-sk
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/home-lab-signing.pub
printf 'owner@example.invalid %s\n' "$(cut -d' ' -f1,2 ~/.ssh/home-lab-signing.pub)" > ~/.ssh/allowed_signers      # so your own git can show G for a good signature
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
cat ~/.ssh/home-lab-signing.pub                  # one line: ssh-ed25519 AAAA... home-lab commit signing
```

Do NOT turn on `commit.gpgsign`: agents and tools commit as you without your key, and that is intended. You sign ONE release commit per deploy with `-S` (below).
Optionally add the same public line to GitHub as a **signing key** (Settings, SSH and GPG keys, New SSH key, type "Signing Key") so the release commit shows as Verified. The
public key is not secret but the real one is not committed here (`config/allowed_signers.example` is only a template). On the Pi, install it (replace the key text; keep ONLY
real key lines in the file, no placeholder line):

```bash
sudo install -m 0644 -o root -g root /dev/null /etc/home-lab/allowed_signers
sudo tee /etc/home-lab/allowed_signers > /dev/null <<'EOF2'
owner@example.invalid namespaces="git" ssh-ed25519 AAAA...your-public-key... home-lab commit signing
EOF2
sudo scripts/preflight.sh --stage full | grep -E 'allowed-signers|ssh-keygen|checkout-owner'      # all PASS
```

**The release loop (everyday).** Agents and you commit normally, unsigned. When you want a change on the Pi:

1. Review everything since the last deployed release: `git log --oneline <last-deployed>..HEAD` and `git diff <last-deployed>..HEAD`. **A signature attests the whole tree**,
   not only your own commits: an unsigned commit underneath your signed one is deployed too, so read agent-written code as untrusted input before you sign.
2. Sign one release commit on top: `git commit --allow-empty -S -m "Release: <what changed>"` (or `git commit -S --amend --no-edit` if the tip is yours and unpushed).
3. `git push`, then on the Pi `sudo scripts/deploy.sh`. Step 1 prints `HEAD <sha>: signature verified against /etc/home-lab/allowed_signers`.

Never run `git pull` on the Pi: `deploy.sh` fetches, verifies the signature BEFORE merging, merges fast-forward only (so an older signed commit cannot roll the Pi back), then
refreshes secrets and starts the stack. An unsigned tip stops step 1 with `not signed by an allowed signer`; nothing is merged or started. The short version of this loop is
in [release-and-deploy.md](release-and-deploy.md).

**Commits made by GitHub are not deployable as they are** (NEW-4, N3): the merge button, squash merge, web edits and Dependabot PRs are signed with GitHub's own key, which is
not in `allowed_signers`, so the Pi refuses them (fails closed, by design). Do not add GitHub's key to `allowed_signers`: that would trust everyone who can click merge. Instead
merge locally and sign on top; the exact steps are in [release-and-deploy.md](release-and-deploy.md) ("Dependabot and GitHub-made commits").

Rotate the signing key by adding the new line, deploying once, then removing the old line. After M6, delete the Pi deploy key and clone over HTTPS
(`sudo git -C /opt/home-lab remote set-url origin https://github.com/<owner>/home-lab.git`, `sudo rm /root/.ssh/home-lab-deploy`).

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
- **Back the CA up now, and prove the backup** (K5): the three files (`ca.key`, `ca.crt`, `issued.tsv`) as an attachment in the password manager AND on a USB stick kept apart from the laptop, the passphrase only in the password manager (its own item, never next to the files),
  then `scripts/pki/test-ca-restore.sh --ca-dir <restored copy>`. Full procedure, refresh rule and the lost-laptop recovery: `ca-backup.md`. Until you do this the CA has no other copy.
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

**After every `sign.sh` run, refresh the CA backup** (`issued.tsv` changed; `ca-backup.md` section 2): replace the files in the password manager item and on the USB stick.

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

## 8. Give Terraform the CA certificate [Owner]

The Roles Anywhere trust anchor, the profiles, the two lab roles and their policies are defined in `terraform/bootstrap` (SEC-H1), which only you apply with your
admin SSO (local execution, state in the HCP workspace `home-lab-bootstrap`). The HCP apply role can no longer create or edit a role. In the gitignored
`terraform/bootstrap/terraform.tfvars` set `ca_cert_pem` to the full PEM of `~/home-lab-ca/ca.crt` (public; BEGIN and END lines included) and, if not default,
`pki_generation`. Also set `domain`, `home_lab_zone_id` and `owner_role_arn_pattern` (see `terraform.tfvars.example`). Do not add `pi_tailnet_ipv4` yet; that is an
`terraform/edge` workspace variable.

## 9. Identity apply [Owner, admin SSO]

```bash
cd terraform/bootstrap
aws sso login --profile henniefrancis
terraform init && terraform plan -out tfplan     # read it; apply only if it matches the list below
terraform apply tfplan
```

On a fresh account with the `ca_cert_pem` set, the plan adds: the trust anchor `home-lab-offline-ca`, profiles `home-lab-traefik` and `home-lab-pi-host`, roles
`home-lab-traefik-dns01` and `home-lab-pi-host` (trust pinned to the trust anchor ARN, the cert CN, the `pki_generation` OU and issuer `home-lab-offline-ca`), their
inline policies, the customer-managed KMS key `alias/home-lab-ssm`, and the apply and plan roles. Nothing is destroyed or replaced. If these objects already exist
(created by the old `terraform/edge` layout) do NOT apply this plan: follow `sec-remediation-apply-order.md`, which imports them so no live role is recreated.
Then set the three edge workspace variables `ra_trust_anchor_arn`, `ra_acme_profile_arn`, `ra_acme_role_arn` from the outputs (`terraform output`) and let the lead apply
`terraform/edge` (it mirrors them into the `config/ra-*` String parameters).

## 10. Write `/etc/home-lab/aws.env` (U13) [Laptop, then Pi]

On the laptop, print the file contents from the Terraform outputs (needs `terraform login` and `TF_CLOUD_ORGANIZATION`; see
`docs/runbooks/hcp-terraform-bootstrap.md`; run `terraform -chdir=terraform/bootstrap init` once if you have not; the outputs now come from the bootstrap stack):

```bash
scripts/render-aws-env.sh --generation gen-1
```

It prints up to eight lines (`AWS_REGION`, `PKI_GENERATION`, `RA_TRUST_ANCHOR_ARN`, `RA_HOST_PROFILE_ARN`, `RA_HOST_ROLE_ARN`, and once those parts of the stack are applied `ALERT_TOPIC_ARN` (K4) and `BACKUP_S3_BUCKET` (K5)); add `--age-recipient age1...` to also print `BACKUP_AGE_RECIPIENT` (K5, `authentik-backup.md` section 1). A line that could not be printed is only a note on stderr, so count the lines. They identify the AWS account, so they
are only for the Pi. Copy them, then on the Pi:

```bash
sudo install -m 0600 -o root -g root /dev/null /etc/home-lab/aws.env
sudo tee /etc/home-lab/aws.env > /dev/null <<'EOF'
(paste all the printed lines here)
EOF
sudo stat -c '%U:%G %a %n' /etc/home-lab/aws.env      # expect: root:root 600 /etc/home-lab/aws.env
```

## 11. Set the required secrets (U12) [Laptop]

`fetch-secrets.sh` **fails closed**: it refuses to publish anything while a required parameter still holds the `UNSET-` placeholder. The required ones are
`authentik/secret-key`, `authentik/postgres-password` and `traefik/breakglass-htpasswd`. If you have not done U12 yet, do it now as described in
`docs/runbooks/secrets-ssm.md` (generate each value in the password manager first):

```bash
aws sso login --profile henniefrancis
scripts/set-secret.sh --check                         # which of the six SecureStrings exist (key and version only)
scripts/set-secret.sh --create <name>                # only for one that is missing (the six are owner-managed, ADR-013)
scripts/set-secret.sh authentik/secret-key          # 60+ characters
scripts/set-secret.sh authentik/postgres-password   # under 99 characters
scripts/set-secret.sh traefik/breakglass-htpasswd   # a bcrypt htpasswd line, see below
```

To make the htpasswd line without putting the password in argv or history (the password manager keeps the plaintext):

```bash
read -rsp 'Break-glass password: ' P && echo && printf '%s\n' "$P" | docker run --rm -i httpd:2.4-alpine htpasswd -nBi -C 12 admin; unset P
```

Type the password at the prompt (nothing is shown) and press Enter; paste the printed `admin:$2y$...` line into the `set-secret.sh` prompt.
`htpasswd -i` on its own shows no prompt and, in Git Bash, may echo what you type, which is why the password is read by the shell first. Optional parameters
(`authentik/bootstrap-password`, `homepage/authentik-token`) can stay UNSET for now. `-C 12` is the bcrypt cost (the default 5 is too cheap to brute-force against); every `set-secret.sh` write
uses the customer-managed key `alias/home-lab-ssm` (`--key-id`), so a value that was stored under the old key is re-encrypted by simply setting it again.

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
| `authentik/secret-key` | `10002:10002` 0400 | the secret (F02, M4: the Authentik service id, not the login user 1000) |
| `authentik/postgres-password` | `10002:10002` 0440 | the secret (PostgreSQL reads it through the group) |
| `authentik/bootstrap-password` | `10002:10002` 0400 | `akadmin` bootstrap password, or an empty file while UNSET (M4) |
| `traefik/breakglass-htpasswd` | `10004:10004` 0400 | the htpasswd line (read by non-root Traefik) |
| `tailscale/tailscale.env` | `0:0` 0600 | `TS_AUTHKEY=...` (empty file once the parameter is UNSET) |
| `runtime.env` | `0:0` 0600 | `DOMAIN`, `ROUTE53_ZONE_ID`, `RA_TRUST_ANCHOR_ARN`, `RA_ACME_PROFILE_ARN`, `RA_ACME_ROLE_ARN` |
| optional files | | omitted while their parameter is UNSET |

Exit codes: 3 = AWS unreachable or access denied (existing secrets untouched), 4 = validation failed (a required parameter is UNSET, missing or the wrong type).

## 14. Start Tailscale [Pi]

```bash
sudo scripts/deploy.sh --only tailscale
sudo docker logs --tail 30 tailscale
sudo docker exec tailscale tailscale --socket=/tmp/tailscaled.sock status
sudo docker exec tailscale tailscale --socket=/tmp/tailscaled.sock ip -4
```

`deploy.sh --only tailscale` fetches the repo, **verifies the commit signature** (section 3.1), merges fast-forward only, refreshes the secrets, then runs
`docker compose -p home-lab -f tailscale/compose.yaml --env-file config/lab.env --env-file /apps/secrets/runtime.env up -d` (from M3 on the root `compose.yaml` includes this stack too; see `m3-traefik-staging.md`). The container uses host networking, state in
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
sudo docker exec tailscale tailscale --socket=/tmp/tailscaled.sock status | head -3
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
sudo sh -c "stat -c '%U:%G %a %n' /apps/.secrets.d /etc/home-lab /etc/home-lab/pki /etc/home-lab/pki/*.key /etc/home-lab/aws.env /etc/home-lab/aws-config"   # sh -c: the glob must expand as root, the pki directory is 0700
sudo stat -L -c '%U:%G %a %n' /apps/secrets          # expect root:root 700
sudo find /apps/.secrets.d -maxdepth 1 -name '.staging-*'   # expect no output (no staging dir left behind)
sudo git -C /opt/home-lab status --ignored --short   # expect nothing secret-looking (a root-owned checkout needs sudo; never git pull, deploy.sh does that)
```

Expected: `host.key` root:root 400, `traefik.key` 10001:10001 400, `/etc/home-lab`, `/etc/home-lab/pki`, `/apps/.secrets.d` and `/apps/secrets` 700 root, `aws.env` and `aws-config` 600.

**Revocation test (manual, with the lead):** the owner bumps `pki_generation` to `gen-2` in a test apply of `terraform/bootstrap`; on the Pi `sudo scripts/fetch-secrets.sh --dry-run` must now fail with
exit 3 (the old certificates no longer match the trust policy); the lead reverts to `gen-1` and confirms the fetch works again. Automated placeholder, interruption and
no-leak checks for `fetch-secrets.sh` run in CI (`scripts/test-fetch-secrets.sh`).

## Renewal and maintenance

- Certificates last 365 days. `scripts/cert-expiry.sh` (also run by `deploy.sh` and the full preflight) WARNs under 30 days and fails under 14; the daily `home-lab-cert-expiry.timer` runs it too (a failing run shows in `systemctl --failed`, `systemctl status home-lab-cert-expiry` and `journalctl -t home-lab-cert-expiry`). **Put a calendar reminder at about day 300** (about 65 days before expiry), because ACME renewal fails first. To renew, repeat steps 5 to 7: `pi-csr.sh` reuses the
  existing keys, you sign on the laptop and install. After a lost or stolen Pi: reissue with a new generation (bump `pki_generation` in `terraform/bootstrap`, apply it with admin SSO, use `--generation gen-2` in
  steps 5 to 7, write `PKI_GENERATION=gen-2` into `aws.env`).
- After any secret changes: `scripts/set-secret.sh <name>` on the laptop, then `sudo scripts/deploy.sh --recreate <stack>` on the Pi (a plain deploy replaces the secret files but does not restart containers; see `rotate-secrets.md`).
- `sudo scripts/deploy.sh --offline` starts from the last-good secrets when AWS or the internet is unavailable. Without `--offline` a failed fetch aborts the deploy.
- The AWS CLI GPG key in `scripts/pubkeys/awscli-team.asc` expires 2027-07-01.

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| `fetch-secrets.sh` exit 3, AWS says `AccessDeniedException` on `CreateSession` or similar | The certificate subject/OU does not match the trust policy, the CA in the trust anchor is not the one that signed the cert (compare fingerprints), or `PKI_GENERATION` and `pki_generation` differ. |
| exit 3 with a clock or signature error | Time sync (preflight `time-sync`). |
| exit 3 `AccessDenied` on `GetParametersByPath` | The pi-host policy needs the path-root ARN (`parameter/home-lab`); verify `terraform/bootstrap` (identity.tf) was applied. First real test of this is step 13. |
| exit 4 `still holds the UNSET placeholder` | Run `scripts/set-secret.sh <name>` for the named parameter (step 11). |
| exit 4 `type is String, expected SecureString` | The parameter was recreated outside Terraform; investigate before continuing. |
| Tailscale `invalid key` or the machine is not tagged | Key expired, was reusable/ephemeral, or lacks `tag:homelab`, or the tag is missing in `tagOwners`. Create a new key, `set-secret.sh tailscale/auth-key`, `sudo scripts/deploy.sh --recreate tailscale`, then unset (`set-secret.sh --unset`) and recreate again. |
| `docker: permission denied` | Expected: your login user is not in the docker group (SEC-M3). Use `sudo docker ...`. |

## What was and was not verified when this runbook was written

Automated (laptop, WSL and CI): shellcheck, yamllint, `docker compose config`, the PKI flow with its refusal cases, `fetch-secrets.sh` against a mock `aws`, and the
preflight script's logic on a non-Pi host, the signed-deploy check with real git and ssh-keygen as root (`scripts/test-deploy.sh`: signed, unsigned, wrong key, unsigned under a signed tip, rollback, detached HEAD, a user-owned or hook-bearing checkout, a wrongly owned `allowed_signers`), `deploy.sh` argument handling, `set-secret.sh` and `aws-preflight.sh --snapshot` against proven mocks, and the Traefik self-test on a Linux runner (non-root uid, read-only, file provider). **Only testable on the Pi, first run by the owner:** the real preflight findings, `bootstrap.sh` (apt, AWS CLI install,
helper download and checksum), `aws_signing_helper` credential-process against the real trust anchor, `GetParametersByPath` on the `/home-lab` path ARN, the Tailscale
container (`/dev/net/tun`, capabilities, `tailscale` CLI socket path) and the S17 results.
