# Runbook: M4 Authentik SSO with enforced MFA, forward auth on the Traefik dashboard

Plan: `docs/plan/phase-1-traefik.md` rev 7 (sections 6.3, 6.4, milestone M4) plus "M4 implementation notes" at its end. Milestone M4 is done when every
check in "Verify" is green.

Everything below runs **on the Pi** in the Raspberry Pi Connect terminal, in the repo checkout, unless it says **[Laptop]**. Do not paste secret values
anywhere. `DOMAIN` is read from the root-only `runtime.env`, so the real domain is never typed into this runbook or git.

## What M4 deploys

| Container | Image | Role |
|-----------|-------|------|
| `authentik-postgresql` | `postgres:16.15-alpine3.24` | database, internal network only, runs as uid 70, 512M |
| `authentik-server` | `ghcr.io/goauthentik/server:2026.8.5` | login UI, OAuth endpoints and the **embedded outpost** (forward auth), `proxy` + internal networks, uid 10002, 1G |
| `authentik-worker` | same image | background tasks and blueprint application, internal network only, **no docker.sock, not root**, uid 10002, 768M |

No Redis (the 2026.8 compose has none). No published ports: everything is reached through Traefik. Traefik now protects `traefik.${DOMAIN}` with
`lan-allowlist@file,authentik@file`; the `bg-traefik` break-glass router (basic auth, no Authentik) is unchanged and stays in the `breakglass` profile.

Configuration is code: `authentik/blueprints/homelab-apps.yaml` creates the group `homelab-admins`, two forward-auth providers and applications
(`traefik`, `dashboard`), binds both applications to that group (fail-closed), enforces MFA, and attaches both providers to the embedded outpost.

Three things worth knowing before you start:

- **F02 (done here):** Authentik runs as uid/gid **10002**, PostgreSQL as its own **70**; neither is a real host user and neither is the login user (1000). The
  Authentik secret files are `10002:10002`; `postgres-password` is `0440` so PostgreSQL reads it through the group. `scripts/bootstrap.sh` creates
  `/apps/authentik/data` (10002) and `/apps/authentik/postgres` (70) with mode 0700; the login user cannot read either.
- **The bootstrap password cannot be a `file://` value.** Authentik reads `AUTHENTIK_BOOTSTRAP_PASSWORD` with a plain environment lookup; a `file://` value would
  literally become the password. The worker therefore starts through a tiny wrapper that exports it from the secret file when the file is non-empty
  (empty file while the SSM parameter is UNSET, so the compose secret always exists). Tested: the `akadmin` password equals the secret file.
- **The first start migrates the database** (several minutes on the Pi's SD card; about 6 minutes on a laptop). The containers show `health: starting`
  and `unhealthy` for a while; that is normal. Do not restart them.

## 0. Owner step [Laptop]: set the bootstrap password (before the first deploy)

Generate a long password in the password manager (this is `akadmin`'s first password; MFA is enforced at the first login anyway). Then:

```bash
aws sso login --profile henniefrancis
scripts/set-secret.sh authentik/bootstrap-password
```

If you skip it, the parameter stays UNSET, the file is empty and Authentik starts with no `akadmin` password: you would then have to use the initial-setup URL
(`https://auth.${DOMAIN}/if/flow/initial-setup/`), which anyone on the LAN or tailnet can open until you do. Setting it is the safer path.

## 1. Before you start

```bash
cd /opt/home-lab
git status --short            # expect nothing
git pull --ff-only
sudo scripts/bootstrap.sh     # idempotent: creates /apps/authentik/data (10002) and /apps/authentik/postgres (70)
sudo scripts/preflight.sh --stage bootstrap | grep -E 'svc-id|authentik|FAIL' 
getent passwd 10002 70 || echo "ids 10002 and 70 are not host users (expected)"
sudo ls -ld /apps/authentik/data /apps/authentik/postgres
```

Expected: no `FAIL`; four `svc-id:` PASS lines; `getent` prints nothing; the two directories show owners `10002 10002` and `70 70`, mode `drwx------`
(`sudo ls -ldn` prints the numeric owners).

## 2. Deploy

```bash
cd /opt/home-lab
sudo scripts/deploy.sh
```

`deploy.sh` pulls, fetches secrets (the three Authentik files appear), pulls the images (about 600 MB for Authentik; arm64), builds `ra-helper` from cache and
starts everything. Traefik is recreated once (its dashboard labels changed) and `ra-helper` with it; expect a few seconds without TLS. Watch the first start:

```bash
dc() { sudo docker compose -p home-lab -f /opt/home-lab/compose.yaml --env-file /opt/home-lab/config/lab.env --env-file /apps/secrets/runtime.env "$@"; }
dc ps --format 'table {{.Name}}\t{{.Status}}'
docker logs --tail 3 authentik-server 2>&1 | cut -c1-160      # "Applying authentik_...": migrations, then the server starts
```

Wait until `authentik-postgresql`, `authentik-server` and `authentik-worker` all say `(healthy)` (give it up to 15 minutes; `dc ps` again every minute).
The `dc` function is used by the later steps too (shell functions do not survive a new terminal tab: define it again).

## 3. Verify the stack

```bash
# 3.1 healthy, identities, memory
dc ps --format 'table {{.Name}}\t{{.Status}}'
for c in authentik-server authentik-worker authentik-postgresql; do printf '%s uid=%s\n' "$c" "$(docker exec "$c" id -u)"; done   # 10002 10002 70
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}' | grep -E 'authentik|NAME'                                    # well under the limits

# 3.2 secret files and data (F02): numeric owners, nothing owned by 1000
sudo ls -ln /apps/secrets/authentik/        # secret-key 10002 10002 -r--------; postgres-password 10002 10002 -r--r-----; bootstrap-password 10002 10002 -r--------
sudo find /apps/secrets /apps/authentik -maxdepth 2 \( -uid 1000 -o -gid 1000 \) | head      # expect no output
LOGIN_USER="$(id -un)"; sudo -u "$LOGIN_USER" cat /apps/secrets/authentik/secret-key 2>&1 | head -1   # Permission denied

# 3.3 hardening: no published ports, no docker.sock, trust only the proxy network, no cookie domain
docker inspect -f '{{.Name}} ports={{json .NetworkSettings.Ports}}' authentik-server authentik-worker authentik-postgresql        # all {}
docker inspect -f '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' authentik-server authentik-worker authentik-postgresql | grep -c docker.sock   # 0
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' authentik-server | grep -E 'TRUSTED_PROXY|COOKIE_DOMAIN|SECRET|PASSWORD'
```

Expected from the last line: `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS=172.30.0.0/24` (the `proxy` network only), `AUTHENTIK_SECRET_KEY=file:///run/secrets/authentik_secret_key`,
`AUTHENTIK_POSTGRESQL__PASSWORD=file:///run/secrets/pg_password`, and **no** `COOKIE_DOMAIN` and no literal secret.

```bash
# 3.4 the blueprint applied
printf '%s\n' 'from authentik.blueprints.models import BlueprintInstance as B' \
  'print("BPSTATE", list(B.objects.filter(name__startswith="Home lab").values_list("name", "status")))' \
  | docker exec -i authentik-worker ak shell 2>/dev/null | grep BPSTATE
```

Expected: `[('Home lab - SSO apps, MFA and embedded outpost', 'successful')]`. (Also visible in the UI: Customization, Blueprints.)

```bash
# 3.5 forward auth answers (from inside the proxy network, bypassing the allowlist, which a loopback curl on the Pi would fail with 403)
DOMAIN="$(sudo sed -n 's/^DOMAIN=//p' /apps/secrets/runtime.env)"
docker exec traefik wget -S -q -O /dev/null --header "X-Forwarded-Host: traefik.$DOMAIN" --header 'X-Forwarded-Proto: https' \
  --header 'X-Forwarded-Uri: /' http://authentik-server:9000/outpost.goauthentik.io/auth/traefik 2>&1 | grep -iE 'HTTP/|location' | cut -c1-120
```

Expected: `HTTP/1.1 302 Found` and `location: https://auth.<domain>/application/o/authorize/?client_id=...` (the `wget: bad address` error that follows is BusyBox trying to
follow the redirect; ignore it). A `404` here means the embedded outpost has not picked up the providers yet: wait a minute and retry; if it persists see Troubleshooting.

## 4. First login as `akadmin` and enrol MFA (the enforced step)

Do this from a device on the LAN or tailnet (the wildcard record resolves to the tailnet IP; a LAN-only device needs a hosts entry for `auth.<domain>`, `traefik.<domain>`).
The browser warns about the certificate while we are on the staging CA: continue.

1. Open `https://auth.<domain>/`. Username `akadmin`, password = the bootstrap password from your password manager.
2. Authentik now **forces MFA setup** (this is the enforced step: there is no "skip"). Choose **TOTP**: scan the QR code (or type the secret) in an authenticator app, enter
   the 6-digit code. (WebAuthn is offered too; a browser may refuse WebAuthn on a staging-CA certificate error. I could not verify that, so use TOTP now and add a security key
   or passkey after M6 gives you a trusted production certificate: User settings, MFA Devices.)
3. You land in Authentik's user portal. Open the **Admin interface** (top right): Directory, Groups: `homelab-admins` exists and contains `akadmin`.
4. Add a **second** MFA device now (another authenticator app or a key), so a lost phone is not a lockout: User settings, MFA Devices.
5. **Tidy up the bootstrap secret** (U10) **[Laptop]**, then recreate the worker so the exported variable is gone from its process:

```bash
scripts/set-secret.sh --unset authentik/bootstrap-password
```

```bash
cd /opt/home-lab
sudo scripts/deploy.sh --no-git --only authentik        # fetches secrets: the bootstrap file becomes empty
dc up -d --force-recreate authentik-worker               # the running worker still has the old value in its environment until recreated
sudo test ! -s /apps/secrets/authentik/bootstrap-password && echo "bootstrap-password file is empty (good)"
```

Changing or removing the bootstrap password later does **not** change `akadmin`'s password (the bootstrap blueprint only creates the user). `akadmin` stays as your MFA-protected
admin; deactivating it before a second admin exists risks a lockout, so do not (create a named admin in `homelab-admins` and `authentik Admins` first if you want one).

## 5. Verify forward auth and MFA end to end (acceptance)

1. **Browser, signed out** (private window): `https://traefik.<domain>/` redirects to `auth.<domain>`, asks for username, password and your TOTP code, and returns to the Traefik dashboard.
2. **Browser, signed in**: opening `https://traefik.<domain>/` again goes straight to the dashboard (SSO). Developer tools, Application, Cookies:
   - on `traefik.<domain>`: `authentik_proxy_...` with **no Domain attribute shown as a leading dot** (host-only), HttpOnly, Secure, SameSite Lax;
   - on `auth.<domain>`: `authentik_session`; and **no** cookie on the parent domain.
3. **[Laptop] signed out, command line** (on Tailscale or with hosts entries; `-k` because the staging certificate is untrusted):

```bash
curl -ski https://traefik.<domain>/ | tr -d '\r' | grep -iE '^HTTP|^location|^set-cookie|^strict-transport'
```

   Expected: `HTTP/2 302`, a `location: https://auth.<domain>/application/o/authorize/...redirect_uri=https%3A%2F%2Ftraefik.<domain>%2Foutpost.goauthentik.io%2Fcallback...`, a `set-cookie: authentik_proxy_...; HttpOnly; SameSite=Lax; Secure; Path=/`
   **without `Domain=`**, and the HSTS header. `curl -ski https://traefik.<domain>/api/rawdata` must also be a 302 (no data without a session).
4. **From outside** (phone on mobile data, Tailscale off): the page does not load (allowlist and tailnet-only address), as in M3.
5. **Fail closed + break-glass** (do this once, it proves the rollback path):

```bash
docker stop authentik-server
```

   From the laptop, with Authentik stopped, `https://traefik.<domain>/` must **not** show the dashboard (an error page, never the dashboard: forward auth fails closed). Then start the break-glass router:

```bash
dc --profile breakglass up -d breakglass
```

   Open `https://bg-traefik.<domain>/`: the browser asks for the break-glass user and password (from the password manager) and shows the dashboard while Authentik is down. Then:

```bash
dc --profile breakglass rm -sf breakglass            # stop and remove the break-glass holder again
docker start authentik-server   # back up; https://traefik.<domain>/ redirects to the login again
```

6. **Group binding (fail-closed)**, optional on the Pi (proved in the local self-test): in the admin UI create a user without adding them to `homelab-admins`; that user can log in to
   Authentik but `https://traefik.<domain>/` shows "Permission denied". Delete the user afterwards.
7. **Headers** reach the backends on routers that use `authentik@file`: the `dashboard` host arrives in M5 (Homepage); until then the self-test proves it with a stand-in
   (`X-authentik-username`, `X-authentik-groups` are set from the session, and a forged value sent by a client is replaced).

## 6. Recovery

| Situation | What to do |
|-----------|------------|
| Lost phone, another MFA device or key still works | Log in with it, User settings, MFA Devices: delete the lost one, add a new one. |
| Lost every MFA device, or the `akadmin` password | Create a one-time recovery link (valid for the minutes you pass, here 15) from the Pi, open it, then fix the account: `docker exec authentik-server ak create_recovery_key 15 akadmin` prints `/recovery/use-token/<token>/`; open `https://auth.<domain>` plus that path **within 15 minutes**. You are logged in as `akadmin`: immediately enrol a new MFA device and, if needed, set a new password (User settings). The link is single use and is not stored anywhere else. |
| Authentik is down or broken, you need the dashboard | Break-glass: `dc --profile breakglass up -d breakglass`, browse `https://bg-traefik.<domain>/` (basic auth). Stop it again with `dc --profile breakglass rm -sf breakglass`. |
| The Pi is unreachable on the network | Raspberry Pi Connect terminal (works without SSH), then the rows above. |
| Database or data directory lost (new SD card) | The blueprint rebuilds groups, applications and providers; **users and MFA devices are gone** until backups exist (a later phase). `scripts/bootstrap.sh`, set `authentik/bootstrap-password`, `sudo scripts/deploy.sh`, log in as `akadmin`, enrol MFA again. |

Authentik secret-key rotation invalidates every session and is not a routine operation; the Postgres password is changed with `ALTER USER` first, then SSM, then deploy (plan R48).

## 7. Rollback

Smallest first.

1. **Dashboard unreachable because of Authentik:** use break-glass (section 6, row 3). Nothing else changes.
2. **Stop Authentik, keep everything else:** `dc stop authentik-server authentik-worker authentik-postgresql`. The dashboard fails closed (it is not served) and `bg-traefik` still works. Data stays.
3. **Back to the M3 state (basic auth in front of the dashboard):** on the laptop `git revert` the M4 commits, push, then on the Pi `sudo scripts/deploy.sh` (a full deploy passes
   `--remove-orphans`, which removes the Authentik containers; `/apps/authentik` data stays). The M3 commit that had basic auth on the dashboard is `12fa978`.
4. **Wipe Authentik completely** (destroys users and MFA devices; only when you really want a clean start):
   `dc rm -sf authentik-server authentik-worker authentik-postgresql && sudo rm -rf /apps/authentik/data /apps/authentik/postgres && sudo scripts/bootstrap.sh`, then deploy again (section 2).

## 8. What only the Pi can verify (everything else ran in `scripts/test-authentik-config.sh`)

arm64 behaviour and first-start duration; real owners and modes on `/apps/secrets` and `/apps/authentik` (the local run used Docker named volumes); the allowlist with a real tailnet
or LAN client in front of forward auth; the memory limits under real use (`docker stats`); a browser with the staging certificate; WebAuthn; the `bg-traefik` flow with the real htpasswd.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `authentik-postgresql` restarts: `data directory ... has wrong ownership` or `Permission denied` | `/apps/authentik/postgres` must be `70:70` 0700: `sudo scripts/bootstrap.sh`. |
| `authentik-server` logs `Permission denied` on `/data` | `/apps/authentik/data` must be `10002:10002` 0700: `sudo scripts/bootstrap.sh`. |
| Server healthy, `forward auth` 404 for the app host | The embedded outpost has not loaded the providers yet (blueprint still applying: check 3.4), or the host in the request carries a port (use the standard port 443) or differs from `external_host`. |
| Login works, then `404` or a loop on `/outpost.goauthentik.io/callback` | The app host has no `<app>-outpost` router. Every host using `authentik@file` needs `Host(<app host>) && PathPrefix(/outpost.goauthentik.io/)` to service `authentik` with `lan-allowlist@file` (see the dashboard labels in `traefik/compose.yaml`). |
| `403` on the dashboard before any login | The allowlist: the client's address is not LAN/tailnet (see R49 in the plan notes: Tailscale must not SNAT). |
| `Permission denied` after a good login | The user is not in `homelab-admins` (Directory, Groups). |
| `ak create_recovery_key` fails with `KeyError: getpwuid()` | The container lost `USER=authentik` from its environment (it is set in `authentik/compose.yaml`); use `docker exec -e USER=authentik ...`. |
| Secret rotated in SSM but Authentik still uses the old value | Containers keep the secret file they were created with: `dc up -d --force-recreate authentik-server authentik-worker` after `deploy.sh`. |
| Blueprint shows `error` | Admin interface, Customization, Blueprints, open the instance for the message; `docker logs authentik-worker 2>&1 | grep -i blueprint`. |
