# Runbook: M8 Pi-hole, DNS for the house, web UI at `pihole.${DOMAIN}`

Plan: R17 build plan (owner-approved 2026-11-10), milestone M8. Self-test: `scripts/test-pihole-config.sh` (CI runs the full test: the real image answering DNS,
the lab names, the web password, the web UI behind forward auth through the real Traefik routers). Prerequisite: M7 is deployed.

Owner decisions (2026-11-10): the whole LAN uses Pi-hole through the router, with the router as the second DNS server, so the house keeps working while the Pi is
down; upstream **Quad9**; the Pi's LAN address comes from SSM (`config/pi-lan-ip`, Terraform) and is never committed.

## What M8 deploys

| Container | Image | Role |
|-----------|-------|------|
| `pihole` | `pihole/pihole:2026.10.1@sha256:...` (official, arm64 in the manifest) | DNS on `0.0.0.0:53` UDP and TCP (**IPv4 only**), web UI on the `proxy` network |

- **DNS answers.**
  - Blocked domains get `0.0.0.0`.
  - The lab names (`auth`, `dashboard`, `traefik`, `bg-traefik`, `tools`, `pihole`, and the planned `links`, `netdata`, `portainer`, `ha`) get the Pi's LAN address.
  - Everything else goes to Quad9, which validates DNSSEC.
  - The apex and `www` are never answered with the Pi.
  - Tailnet devices keep using public DNS: the public wildcard record still points at the tailnet address, and Pi-hole is only for the LAN.
- **IPv4 only.** The Pi has a global IPv6 address and no IPv6 firewall, so `[::]:53` would be an open resolver on the internet. `preflight.sh` fails on any IPv6 DNS
  listener (`dns-ipv6`).
- **Identity.** The image's start script runs as root only to set up. FTL, which serves DNS and the web UI, then runs as **uid 10006**. The image default is 1000, which is
  your login user, so it is overridden.
  - Capabilities are the documented minimum for "no DHCP, no NTP": `CHOWN DAC_OVERRIDE FOWNER SETUID SETGID SETFCAP NET_BIND_SERVICE`.
  - FTL itself ends up with only `NET_BIND_SERVICE` effective.
  - `no-new-privileges` is not set, because the image grants FTL its port-53 capability as a file capability and that setting would block it. The alternative is FTL as root.
  - The root file system stays writable, because the start script edits `/etc/passwd` for the uid.
- **Web UI.** `https://pihole.<domain>/admin/` sits behind Authentik forward auth (provider `homelab-pihole`, group `homelab-admins`), then Pi-hole's own password. The
  password comes from the SSM SecureString `pihole/admin-password`, as a file, and never from the environment.
- **Settings are code.** Every setting passed as `FTLCONF_*` is read-only in the web UI; change it in `pihole/compose.yaml`. Blocklists and allow/deny entries you add in the
  UI are kept in `/apps/pihole/etc-pihole`.
- **SD-card wear.** The query history keeps 7 days, and the logs are in memory.

## 1. Before you start [Owner]

1. **Terraform, the Pi's LAN address.**
   - In HCP Terraform, workspace `home-lab`, Variables, add a **Terraform** variable `pi_lan_ipv4` (not sensitive). Its value is the Pi's reserved LAN address, the one your router's DHCP reservation gives it.
   - Then tell Claude, who runs the plan.
   - Expect one SSM parameter added (`/home-lab/config/pi-lan-ip`) and nothing destroyed.
   - You approve the apply.
2. **The Pi-hole admin password.** On the laptop, in Git Bash, run the two commands below. Generate the password in your password manager and keep it there; it is never typed into chat.
   ```bash
   cd /a/henniefrancis/home-lab-new
   scripts/set-secret.sh --create pihole/admin-password    # creates it with the UNSET placeholder (version 1); no prompt
   scripts/set-secret.sh pihole/admin-password             # prompts with no echo: paste the password (version 2)
   ```
   Check with `scripts/set-secret.sh --check`: `pihole/admin-password` must show **version 2 or higher**. Version 1 is still the placeholder, and the deploy
   fails closed on it.
3. The signed release is pushed and CI is green on it (`release-and-deploy.md`).

## 2. Deploy [Pi]

```bash
cd /opt/home-lab
sudo scripts/deploy.sh --only it-tools      # fetches and verifies the new release; redeploys only IT Tools (nothing changes there)
sudo scripts/bootstrap.sh                   # creates /apps/pihole/etc-pihole owned by 10006 (and re-checks the rest)
sudo scripts/deploy.sh                      # the whole lab: pulls Pi-hole and starts it
```

The first run downloads the default blocklist. Authentik re-applies the changed blueprint by itself in about 25 minutes. Until then `pihole.` shows the outpost's 404
page; **do not start a manual `apply_blueprint`** ([[m4-authentik]] 3.4a).

## 3. Verify on the Pi (read-only)

```bash
sudo docker compose -p home-lab ps pihole                                                   # Up ... (healthy)
sudo docker exec pihole sh -c 'awk "/^Uid:|^CapEff:/" /proc/$(pidof pihole-FTL)/status'      # Uid 10006 ..., CapEff 0000000000000400
D=$(sudo grep -oP '^DOMAIN=\K.*' /apps/secrets/runtime.env); L=$(sudo grep -oP '^PI_LAN_IP=\K.*' /apps/secrets/runtime.env)
q() { sudo docker exec pihole dig +short @127.0.0.1 "$@"; }   # dig inside the container (the Pi host may have no dig)
q tools.$D          # the LAN address ($L)
q www.$D            # NOT the LAN address
q doubleclick.net   # 0.0.0.0 (blocked)
sudo scripts/preflight.sh --stage full | grep -E 'dns-ipv6|pihole|FAIL|Summary'             # dns-ipv6 PASS, pihole-data PASS, 0 FAIL
```

## 4. Switch the house to Pi-hole [Owner, router]

In the router's admin page, under LAN and DHCP settings:
1. **DNS server 1:** the Pi's LAN address.
2. **DNS server 2:** the router itself, or the DNS it used before.
3. Save. Devices pick it up when they renew their lease: reconnect Wi-Fi on a phone and laptop to test.

**Before the router change, test the published port from the laptop:** `nslookup tools.<domain> <Pi LAN address>` answers the LAN address and
`nslookup doubleclick.net <Pi LAN address>` answers `0.0.0.0`.

**After it, verify from a laptop on the LAN:** `nslookup tools.<domain>` answers the LAN address, and `https://tools.<domain>` works **without** Tailscale. In the Pi-hole UI,
Query Log shows the laptop's own address.

## 5. Browser check [Owner, browser]

1. `https://pihole.<domain>/admin/`: the Authentik login, then Pi-hole's login. Use the password from the password manager. You land on the dashboard.
2. `https://dashboard.<domain>`: the Pi-hole tile is in the Tools group and opens the UI.

## 6. Rollback

- **House DNS first:** in the router, set DNS back to what it was before. Within a lease renewal every device stops using Pi-hole.
- **Stop Pi-hole:** `sudo docker compose -p home-lab stop pihole`. With the router still on Pi-hole first, devices fall back to DNS server 2, which can take seconds per lookup, so
  change the router too.
- **Undo the milestone:** make a signed revert commit, push, wait for CI, then run `sudo scripts/deploy.sh` and `sudo docker rm -f pihole`. `/apps/pihole/etc-pihole` stays until you
  delete it. Leaving the SSM parameters in place is harmless.

## 7. What only the Pi and the house can verify

- Real LAN clients and the router's DHCP behaviour; the query log showing real client addresses.
- The real Authentik login for the new provider (the self-test uses a stub outpost).

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `deploy.sh` stops at fetch-secrets: `config/pi-lan-ip` missing | Section 1.1 is not done yet (the HCP apply) |
| `deploy.sh` stops at fetch-secrets: `pihole/admin-password` placeholder | Section 1.2 is not done yet (`set-secret.sh`) |
| `pihole` restarts, log says "Unable to set capabilities" | A capability was removed from `pihole/compose.yaml`; the image needs exactly the listed set |
| `bind: address already in use` for port 53 | Something on the host listens on 53 (a `systemd-resolved` stub, for example): `sudo ss -tulpn | grep ':53 '` |
| Lab names do not resolve on the LAN | The device still uses the old DNS (renew the lease), or `PI_LAN_IP` is wrong: compare section 3 with the router's reservation |
| Some ads still appear | Expected sometimes: devices also use DNS server 2 (the router), which does not block |
