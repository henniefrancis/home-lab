# Runbook: R19 apps (M13 bumps, M14 Koffan, M15 Speedtest Tracker, M16 CouchDB for LiveSync, M17 n8n), in ONE release and ONE deploy

Plan: the R19 build plan (owner-approved 2026-11-11); ADR-018 (root-start containers, `docs/decisions/ADR-018-root-start-containers.md`).
Everything ships as one signed release and one deploy. No Terraform change: the Route 53 wildcard already answers the new names, the SecureStrings are
script-managed (ADR-013) and the Pi role already writes under `apps/`. Do NOT start a manual Authentik blueprint apply.

Self-tests (CI runs each one in full): `test-koffan-config.sh`, `test-speedtest-config.sh`, `test-couchdb-config.sh`, `test-n8n-config.sh`,
`test-container-rules.sh` (the ADR-018 guard), `test-backup-apps.sh`, `test-homeassistant-config.sh` (now with a login-flow check through Traefik),
and the updated `test-authentik-config.sh` (a real Authentik applies all ten applications).

## What this release adds

| App | Address | Login | Notes |
|-----|---------|-------|-------|
| Home Assistant 2026.11.1, Linkwarden v2.17.0 | `ha.`, `links.` | unchanged | Version bumps only. HA 2026.11 refuses a non-local login whose client id does not match scheme, host and port ("Invalid client id"); CI proves it through Traefik. nginx-unprivileged stays on the even 1.30 line (Dependabot ignore) |
| Koffan | `https://shopping.<domain>` | Authentik forward auth (admins and users); Koffan's own login is off | One shared household list. A phone PWA: the manifest, icons and service worker are served without login by a static-only router |
| Speedtest Tracker | `https://speedtest.<domain>` | Authentik forward auth (admins); the app's admin login only for settings | Root start, ADR-018. Measures at `17 */6 * * *` (about 20 GB a month at 100/50 Mbps). Not backed up |
| CouchDB (LiveSync) | `https://couchdb.<domain>` | CouchDB user `livesync` (the plugin). Allowlist only, NO forward auth | No web UI (Fauxton is blocked), no Homepage tile. Phones sync over Tailscale. End-to-end encryption passphrase never reaches the Pi |
| n8n | `https://n8n.<domain>` | Authentik forward auth (admins), then n8n's own owner login | Webhooks and forms: LAN and tailnet only, no Authentik. Rule: every production Webhook node uses Header Auth or Basic Auth |
| App backups | `s3://<bucket>/apps/<job>/` | - | New nightly jobs: `koffan-db`, `n8n-db` (SQLite, consistent copy as the app uid in a tmpfs), `n8n-files`, `couchdb`. Speedtest: none |

## 1. Before the deploy [Owner, laptop]

No Terraform in R19.

1. **Machine-only secrets, ONE command** (random values straight into SSM; nobody sees them):
   ```bash
   scripts/set-secret.sh --generate n8n/encryption-key couchdb/admin-password couchdb/cookie-secret speedtest/app-key
   ```
   The n8n key encrypts every credential n8n stores: SSM is its only copy (it is deliberately NOT in the backup). Never overwrite it later.
2. **Two human passwords** (use your password manager; each is created, then set at the prompt):
   ```bash
   scripts/set-secret.sh --create couchdb/sync-password && scripts/set-secret.sh couchdb/sync-password
   scripts/set-secret.sh --create speedtest/admin-password && scripts/set-secret.sh speedtest/admin-password   # 64 characters or fewer
   ```
3. `scripts/set-secret.sh --check` must end with `check OK` (18 SecureStrings).
4. Make sure the branch is merged, CI is green on the exact commit, and **sign the release**.

## 2. Restore point [Pi]

`sudo systemctl start home-lab-backup-apps.service`, then `journalctl -u home-lab-backup-apps.service -n 40`: every job OK. This gives a fresh
Linkwarden database and Home Assistant config before their upgrades. (The new jobs report "skipped" until their directories exist.)

## 3. The one deploy [Pi]

```bash
sudo scripts/deploy.sh --only it-tools      # fetch and verify the signed release and the secrets
sudo scripts/bootstrap.sh                   # installs sqlite3, creates the new data directories (0700, per-app uid)
sudo scripts/deploy.sh                      # the whole lab
```
Wait up to about 35 minutes for the Authentik blueprint (ten applications). Do not start a manual apply.

## 4. Verify on the Pi (read-only)

- `docker compose -p home-lab ps`: every service Up or healthy, and `couchdb-init` **Exited (0)** (expected: it is a one-shot).
- `sudo scripts/preflight.sh --stage full`: no FAIL (new checks: `koffan-data`, `speedtest-config`, `n8n-data`, `couchdb-data`, `couchdb-etc`, `sqlite3`, `setpriv`).
- `sudo systemctl start home-lab-backup-apps.service`: the new jobs `koffan-db`, `n8n-db`, `n8n-files`, `couchdb` are OK. (The backup's SQLite step needs
  `/dev/shm` as a tmpfs inside the unit's sandbox; if a job says "is not a tmpfs", see Troubleshooting.)

## 5. First use [Owner], in this order

1. **n8n owner first.** `https://n8n.<domain>`: Authentik login, then create the n8n owner account (password manager; optionally n8n's own MFA).
   Whoever reaches the setup page first becomes the owner; only admins can get there.
2. **Home Assistant Companion retest.** Log out and in on the phone app, on the LAN and over Tailscale. On "Invalid client id" see Rollback.
3. **Linkwarden.** Sign in again in the browser extension if it asks.
4. **Koffan as a phone PWA.** `https://shopping.<domain>`, Authentik login, "Add to Home Screen" / "Install". It must open standalone, add an item, show it on a
   second device in real time, and work offline then sync. Recheck the next day after the 12-hour Authentik session has expired. (CI cannot test this.)
5. **LiveSync from a phone over Tailscale.** Install the plugin, remote type CouchDB, URI `https://couchdb.<domain>`, user `livesync`, the sync password,
   database `obsidian`, end-to-end encryption ON with a NEW passphrase (password manager). Skip the plugin's "fix database configuration": the server is
   already configured and the sync user is not a server admin. Sync on Wi-Fi without Tailscale, then on mobile data with Tailscale, then confirm it pauses with
   Tailscale off.
6. **Speedtest.** `https://speedtest.<domain>` shows the dashboard. The first result appears after the next `:17` of a 6-hour slot (or "Run speedtest" in the admin
   panel, signed in with `admin@<domain>` and the password from step 1). To pin a server later, set `SPEEDTEST_SERVERS` in `config/lab.env` in a later release.
7. **Homepage.** Three new tiles (Shopping list, n8n, Speedtest Tracker).

## 6. Rules

- n8n webhooks use Header Auth (or Basic Auth) credentials: the LAN and the tailnet reach them without Authentik. Watch n8n's security advisories and bump out of
  cycle for a critical one. Community packages, the public API and environment access from Code nodes are off.
- A Form Trigger page may load static files that forward auth blocks. If a form renders without styling, record the asset path it requests and ask for a test
  before adding ONLY that static path to the `n8n-hooks` router (never `/rest/`).
- Change the speed test schedule only in `config/lab.env` (`SPEEDTEST_SCHEDULE`): signed release, then `sudo scripts/deploy.sh --recreate speedtest`.
- Accepted: anything on the `proxy` network can reach `koffan:8080` without a login (like IT Tools); the data is a shopping list.

## 7. Rollback

- **One app:** `sudo docker compose -p home-lab stop <service>`; its router answers 502. Nothing depends on the four new apps.
- **Home Assistant 2026.11.1 login breaks:** check the trusted proxies first (the seeded values). If still broken, a signed commit pins 2026.10.4 back; if HA refuses its
  migrated `.storage`, restore the step 2 backup.
- **Linkwarden v2.17.0:** pin v2.16.3 back. If Prisma migrations ran, restore `linkwarden-db` from the step 2 backup (`pg_restore --clean`).
- **The release:** a signed revert commit, push, CI, `sudo scripts/deploy.sh`, then `sudo docker rm -f` the removed containers. Data stays under `/apps/<app>`; the SSM
  parameters, Authentik entries and S3 objects can stay.
- **CouchDB:** the devices keep their full vault locally, so stopping CouchDB loses nothing. Re-enable sync after the fix.

## 8. Restoring an app backup (R19 jobs)

Objects are age-encrypted: `age -d -i <your identity> <object>`. Stop the app first (`sudo docker compose -p home-lab stop <service>`).

- **Koffan / n8n database (`*.sqlite.age`):** decrypt to the database file (`/apps/koffan/data/shopping.db`, `/apps/n8n/data/database.sqlite`), **delete any `-wal` and
  `-shm` file** next to it, `chown` it to the app uid (10008 / 10010) with mode 0600, start the app. n8n also needs the SAME key: `/apps/secrets/n8n/encryption-key` comes from SSM
  (`n8n/encryption-key`) on the next deploy, never from the backup.
- **n8n files (`n8n-files`):** `tar -xf` into `/apps/n8n` (it holds `data/binaryData` etc. but not the database or n8n's config file), then restore the database as above.
- **CouchDB (`couchdb`):** unpack into `/apps/couchdb` (`data/` and `etc/`), `chown -R 10011:10011 /apps/couchdb/data /apps/couchdb/etc`, start. `etc/docker.ini` holds the hashed admin password.

## Troubleshooting

- **n8n: "Invalid origin" or login loops:** the host, protocol and proxy hops are set in `n8n/compose.yaml` (`N8N_HOST`, `N8N_PROTOCOL`, `N8N_PROXY_HOPS=1`); check `docker logs n8n`.
- **A webhook returns the Authentik login page:** the URL does not start with an exact prefix of the `n8n-hooks` router (`/webhook/`, `/webhook-test/`, `/webhook-waiting/`, `/form/`, `/form-test/`, `/form-waiting/`).
- **CouchDB: the plugin says CORS or 401:** check `docker logs couchdb-init` (exit 0) and that the URL is `https://couchdb.<domain>` with user `livesync`. Traefik must add no CORS header; CouchDB's own comes from `couchdb/livesync.ini`.
- **Rotating the CouchDB admin password:** after `set-secret.sh`, stop CouchDB, delete the `[admins]` section from `/apps/couchdb/etc/docker.ini` (the entrypoint adds it only once), deploy, then `docker compose -p home-lab up -d couchdb-init`.
- **Changing the sync password:** set `couchdb/sync-password`, deploy; `couchdb-init` finds the old password no longer works and rewrites the user.
- **Speedtest never produces a result:** see `docker logs speedtest-tracker`; the first test waits for the next `:17` in a 6-hour slot. If the container sits at "An application key is missing", `speedtest/app-key` is not 64 hex characters.
- **Backup job says "is not a tmpfs":** the unit's sandbox did not keep `/dev/shm` as a tmpfs. Do not weaken the check; report it (the SQLite copy must never touch the SD card).
- **Backup job says "owned by root":** the app's database file must be owned by its service uid (10008 / 10010); fix with `chown`, never run sqlite3 as root next to a live database.
