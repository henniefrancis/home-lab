# Runbook: R17 apps (M9 Linkwarden, M10 Netdata, M11 Portainer, M12 Home Assistant) and app backups, in ONE release and ONE deploy

Plan: R17 build plan (owner-approved 2026-11-10) and the batch notes; ADR-017 (Docker socket for Portainer and Netdata). Owner decision
2026-11-10: the rest of R17 ships as one signed release and one deploy. M7 (IT Tools, `m7-it-tools.md`) and M8 (Pi-hole, `m8-pihole.md`)
are already live.

Self-tests (CI runs each one in full): `test-linkwarden-config.sh`, `test-netdata-config.sh` (the container part on the Linux runner),
`test-portainer-config.sh`, `test-homeassistant-config.sh` (watches Home Assistant across its 5-minute settings window),
`test-backup-apps.sh`, plus the updated `test-authentik-config.sh` (a real Authentik applies the blueprint with all seven apps).

## What this release adds

| App | Address | Login | Notes |
|-----|---------|-------|-------|
| Linkwarden + Meilisearch + PostgreSQL | `https://links.<domain>` | **Authentik OIDC** (button "Home lab login"); Linkwarden's own password login and sign-up are off | For you and the household: Authentik group `homelab-users` (new, empty; you add people) and `homelab-admins` |
| Netdata | `https://netdata.<domain>` | Authentik forward auth (admins) | Host network; listens ONLY on 172.30.0.1 and loopback; no Netdata Cloud, no telemetry |
| Portainer CE | `https://portainer.<domain>` | Authentik forward auth (admins), then Portainer's admin login | Docker socket (ADR-017). Rule: view, logs, restart only; the repo stays the source of truth |
| Home Assistant | `https://ha.<domain>` | Home Assistant's own users with TOTP (Companion app) | Host network, listens ONLY on 172.30.0.1; Bluetooth on (BlueZ over D-Bus); Zigbee later (M12b) |
| App backups | `s3://<bucket>/apps/<job>/` | - | Nightly 03:15: Linkwarden database and saved pages, Home Assistant config (not the history database), Pi-hole settings (not the query log), Portainer data. Age-encrypted on the Pi first |

Also in this release (no action needed): the `oidc` Docker network (Linkwarden's server-side login check reaches Authentik there), the
Authentik router's `oidc-allowlist`, H2 narrowed (avahi stays masked; Bluetooth comes back for Home Assistant), preflight checks
`ha-listen`, `bluetooth`, `apps-root`, the M8 fix release (`pihole-data` mode) and the Terraform change below.

## 1. Before the deploy [Owner, laptop] - about 10 minutes

1. **Terraform (bootstrap stack, app backups).** The Pi role may write under `apps/` too, with the same retention as the Authentik dumps.
   Claude runs the plan; expected: `0 to add, 2 to change, 0 to destroy` (the Pi role's policy, the bucket lifecycle). You approve the apply.
2. **Machine-only secrets, ONE command** (random values straight into SSM; nobody sees them):
   ```bash
   cd /a/henniefrancis/home-lab-new && scripts/set-secret.sh --generate linkwarden/postgres-password linkwarden/nextauth-secret linkwarden/meili-key linkwarden/oidc-client-secret
   ```
3. **Portainer admin password** (a human password: generate it in your password manager and keep it there). **64 characters or fewer**:
   Portainer hashes it with bcrypt, which stops at 72 bytes, and refuses to start with a longer one (`set-secret.sh` refuses it too):
   ```bash
   scripts/set-secret.sh --create portainer/admin-password && scripts/set-secret.sh portainer/admin-password
   ```
4. **Check:** `scripts/set-secret.sh --check` lists every SecureString, Portainer at version 2, the four Linkwarden ones at version 1 (a generated
   value, not a placeholder).
5. **Sign the release** (Claude pushes and waits for CI on that exact commit).

## 2. The one deploy [Pi]

```bash
cd /opt/home-lab
sudo scripts/deploy.sh --only it-tools      # fetches and verifies the release (changes nothing on IT Tools)
sudo scripts/bootstrap.sh                   # new networks (oidc, linkwarden-internal), directories, Home Assistant seed, Bluetooth, backup timer
sudo scripts/deploy.sh                      # starts everything (Linkwarden is a 2.5 GB image: allow a few minutes on the Pi)
```

Authentik applies the changed blueprint by itself in about 25 minutes (7 applications). **Do not start a manual `apply_blueprint`**
(`m4-authentik.md` 3.4a). Until then the new hosts answer the outpost's 404 page (Netdata, Portainer) or Linkwarden's login button fails.

## 3. Verify on the Pi (read-only; Claude runs these)

```bash
sudo docker compose -p home-lab ps                           # every container Up, the ones with a health check (healthy)
sudo scripts/preflight.sh --stage full | grep -E 'FAIL|Summary|ha-listen|dns-ipv6|bluetooth|apps-root'
sudo ss -tlnH | awk '{print $4}' | grep -E ':(8123|19999)$'  # only 172.30.0.1:8123, 172.30.0.1:19999 and 127.0.0.1:19999
sudo systemctl start home-lab-backup-apps.service && sudo journalctl -u home-lab-backup-apps -n 20 --no-pager   # every job "OK"
```

## 4. First use [Owner, browser] - in this order, right after the deploy

1. **Home Assistant first** (whoever opens it first becomes its owner): `https://ha.<domain>`, create your owner account, then Profile,
   Security, enable **TOTP** (multi-factor authentication). Install the Companion app and point it at `https://ha.<domain>`.
2. **Linkwarden:** give every user an e-mail address in Authentik (Directory, Users) first, then `https://links.<domain>`, "Home lab login".
   For household members: Authentik, Directory, Groups, `homelab-users`, add them.
3. **Portainer:** `https://portainer.<domain>`: Authentik, then Portainer's login (`admin` and the password from step 1.3). The local Docker
   environment is already there.
4. **Netdata:** `https://netdata.<domain>`. If it offers a Netdata Cloud sign-in, choose to skip it and use the local dashboard.
5. **Homepage:** every tile is live; nothing is left in "Coming soon".

## 5. Rollback

- **One app:** `sudo docker compose -p home-lab stop <service>`; its Traefik router then answers 502. Nothing else depends on it.
- **The release:** a signed revert commit, push, CI, `sudo scripts/deploy.sh`, then `sudo docker rm -f` the removed containers. Data stays under
  `/apps/<app>` until you delete it. The SSM parameters, the Authentik entries and the `apps/` backups can stay.
- **Home Assistant listening too widely** (preflight `ha-listen` FAIL): Settings, System, Network, HTTP server: listen address `172.30.0.1`,
  trusted proxies `172.30.0.0/24`, and confirm within 5 minutes. Or stop it, restore `homeassistant/seed/.storage/http` into
  `/apps/homeassistant/config/.storage/http`, start it.

## 6. Restoring an app backup

Same pattern as the Authentik restore (`authentik-backup.md` sections 4 to 6): pick the newest object that has its `.ok` marker under
`apps/<job>/`, download it on the laptop, `age -d -i <identity>`, then for a `.tar` stop the app and unpack it into `/apps/<app>/` (owner
and mode as `bootstrap.sh` creates them), for `linkwarden-db` stop Linkwarden and `pg_restore --clean` into `linkwarden-postgresql`.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `deploy.sh` stops at fetch-secrets: a Linkwarden or Portainer parameter is missing | Section 1.2 or 1.3 not done |
| Linkwarden's login button returns an error | Authentik has not applied the blueprint yet (wait up to 25 minutes), or the user has no e-mail in Authentik |
| Linkwarden log: `invalid_api_key` (Meilisearch) | `linkwarden/meili-key` changed after the first start: the search index keeps the old key. Stop both, delete `/apps/linkwarden/meili/*`, start again (the index is rebuilt) |
| Netdata or Home Assistant: 502 through Traefik | It is not listening on 172.30.0.1 (the proxy network must exist before it starts): `sudo scripts/deploy.sh --recreate netdata` or `homeassistant` |
| Portainer keeps restarting, log: `failed hashing admin password ... password length exceeds 72 bytes` | The password is too long for bcrypt. Set a shorter one (`scripts/set-secret.sh portainer/admin-password`), then `sudo scripts/deploy.sh --recreate portainer` |
| Home Assistant does not see Bluetooth devices | `systemctl is-enabled bluetooth` must not say `masked`: `sudo scripts/bootstrap.sh` |
| `ha-listen` FAIL in preflight | Section 5, last item |
