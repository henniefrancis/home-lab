# Runbook: M4 Authentik SSO with enforced MFA, forward auth on the Traefik dashboard

Plan: `docs/plan/phase-1-traefik.md` rev 7 (sections 6.3, 6.4, milestone M4) plus "M4 implementation notes" at its end. Milestone M4 is done when every
check in "Verify" is green.

Everything below runs **on the Pi** in the Raspberry Pi Connect terminal, in the repo checkout, unless it says **[Laptop]**. Do not paste secret values
anywhere. `DOMAIN` is read from the root-only `runtime.env`, so the real domain is never typed into this runbook or git.

## What M4 deploys

| Container | Image | Role |
|-----------|-------|------|
| `authentik-postgresql` | `postgres:16.15-alpine3.24@sha256:...` | database, internal network only, runs as uid 70, 512M |
| `authentik-server` | `ghcr.io/goauthentik/server:2026.8.5@sha256:...` | login UI, OAuth endpoints and the **embedded outpost** (forward auth), on `authentik-auth` (shared with Traefik only) + internal networks, uid 10002, 1G |
| `authentik-worker` | same image | background tasks and blueprint application, internal network only, **no docker.sock, not root**, uid 10002, 768M |

No Redis (the 2026.8 compose has none). No published ports: everything is reached through Traefik. Traefik now protects `traefik.${DOMAIN}` with
`lan-allowlist,authentik` (file provider, `traefik/dynamic/routers.yml`). The `bg-traefik` break-glass router (basic auth, no Authentik) exists only while `sudo scripts/breakglass.sh on` is active (see section 5, step 5, and the hardening notes below).

**Network trust (SEC-L8).** `authentik-server` is not on the `proxy` network any more: it sits on `authentik-auth`, which only Traefik shares, and `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` is that subnet. Homepage and every other container on `proxy` cannot reach `authentik-server:9000`, so none of them can forge `X-Forwarded-*` headers or call the outpost directly.

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
sudo git -C /opt/home-lab status --short   # expect nothing (the checkout is root-owned: plain git says "dubious ownership")
sudo scripts/deploy.sh --only tailscale   # brings the checkout to the latest SIGNED release (never git pull: it would skip the signature check)
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

`deploy.sh` fetches and signature-verifies the commit, fetches secrets (the three Authentik files appear), pulls the images (about 600 MB for Authentik; arm64), builds `ra-helper` from cache and
starts everything. Traefik is recreated once (non-root, no Docker provider, new routers file) and `ra-helper` with it; expect a few seconds without TLS. Watch the first start:

```bash
dc() { sudo docker compose -p home-lab -f /opt/home-lab/compose.yaml --env-file /opt/home-lab/config/lab.env --env-file /apps/secrets/runtime.env "$@"; }
dc ps --format 'table {{.Name}}\t{{.Status}}'
sudo docker logs --tail 3 authentik-server 2>&1 | cut -c1-160      # "Applying authentik_...": migrations, then the server starts
```

Wait until `authentik-postgresql`, `authentik-server` and `authentik-worker` all say `(healthy)` (give it up to 15 minutes; `dc ps` again every minute).
The `dc` function is used by the later steps too (shell functions do not survive a new terminal tab: define it again).

## 3. Verify the stack

```bash
# 3.1 healthy, identities, memory
dc ps --format 'table {{.Name}}\t{{.Status}}'
for c in authentik-server authentik-worker authentik-postgresql; do printf '%s uid=%s\n' "$c" "$(sudo docker exec "$c" id -u)"; done   # 10002 10002 70
sudo docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}' | grep -E 'authentik|NAME'                                    # well under the limits

# 3.2 secret files and data (F02): numeric owners, nothing owned by 1000
sudo ls -ln /apps/secrets/authentik/        # secret-key 10002 10002 -r--------; postgres-password 10002 10002 -r--r-----; bootstrap-password 10002 10002 -r--------
sudo find /apps/secrets /apps/authentik -maxdepth 2 \( -uid 1000 -o -gid 1000 \) | head      # expect no output
LOGIN_USER="$(id -un)"; sudo -u "$LOGIN_USER" cat /apps/secrets/authentik/secret-key 2>&1 | head -1   # Permission denied

# 3.3 hardening: no published ports, no docker.sock, trust only the proxy network, no cookie domain
sudo docker inspect -f '{{.Name}} ports={{json .NetworkSettings.Ports}}' authentik-server authentik-worker authentik-postgresql        # all {}
sudo docker inspect -f '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' authentik-server authentik-worker authentik-postgresql | grep -c docker.sock   # 0
sudo docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' authentik-server | grep -E 'TRUSTED_PROXY|COOKIE_DOMAIN|SECRET|PASSWORD'
```

Expected from the last line: `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS=172.30.0.0/24` (the `proxy` network only), `AUTHENTIK_SECRET_KEY=file:///run/secrets/authentik_secret_key`,
`AUTHENTIK_POSTGRESQL__PASSWORD=file:///run/secrets/pg_password`, and **no** `COOKIE_DOMAIN` and no literal secret.

```bash
# 3.4 the blueprint applied
printf '%s\n' 'from authentik.blueprints.models import BlueprintInstance as B' \
  'print("BPSTATE", list(B.objects.filter(name__startswith="Home lab").values_list("name", "status")))' \
  | sudo docker exec -i authentik-worker ak shell 2>/dev/null | grep BPSTATE
```

Expected: `[('Home lab - SSO apps, MFA and embedded outpost', 'successful')]`. (Also visible in the UI: Customization, Blueprints.)

### 3.4a Blueprint progress on a Pi: how to check, how long it takes, the manual fallback (F06)

**Expect a long wait on a Pi 4 with an SD card: about 25 minutes from the first `up` to a fully applied blueprint** (M4 deploy, 2026-11-08). The worker applies the stock
blueprints one after the other (each is many small database writes, slow on SD), and until it has applied them our blueprint cannot find the flows it needs. For about 4 of those
minutes `BlueprintInstance.status` stayed `unknown` for four instances (ours, `system/providers-oauth2.yaml`, the default implicit-consent authorization flow, the default
source-enrollment flow) before they went to `successful`; the providers appeared only afterwards. That is slow, not broken: do not restart the worker while it is applying
(a restart starts the queue again). Any later edit of `authentik/blueprints/homelab-apps.yaml` (for example for a new app) is re-applied the same slow way: allow up to ~25 minutes
on the Pi and check with the commands below before testing the app. M5 (Homepage) did not change the blueprint, so it adds no wait.

Check progress (all read-only; run on the Pi):

```bash
# 1. All blueprint instances and their status (successful / unknown / error / orphaned). "unknown" for a few minutes is normal while queued.
printf '%s\n' 'from authentik.blueprints.models import BlueprintInstance as B' \
  'print("BP", [(b.status, b.name) for b in B.objects.order_by("name")])' \
  | sudo docker exec -i authentik-worker ak shell 2>/dev/null | grep '^BP'
# 2. Are the objects there? Providers, applications, the outpost binding, the admin group.
printf '%s\n' 'from authentik.providers.proxy.models import ProxyProvider as P' 'from authentik.core.models import Application as A, Group as G' \
  'from authentik.outposts.models import Outpost as O' \
  'print("PROV", sorted(P.objects.values_list("name", "mode")))' 'print("APPS", sorted(A.objects.values_list("slug", flat=True)))' \
  'print("OUTPOST", [(o.name, sorted(o.providers.values_list("name", flat=True))) for o in O.objects.all()])' \
  'print("GROUP", list(G.objects.filter(name="homelab-admins").values_list("name", flat=True)))' \
  | sudo docker exec -i authentik-worker ak shell 2>/dev/null | grep -E '^(PROV|APPS|OUTPOST|GROUP)'
# 3. MFA enforced: the validation stage must be set to "configure" (not "skip").
printf '%s\n' 'from authentik.stages.authenticator_validate.models import AuthenticatorValidateStage as S' \
  'print("MFA", list(S.objects.filter(name="default-authentication-mfa-validation").values_list("not_configured_action", "device_classes")))' \
  | sudo docker exec -i authentik-worker ak shell 2>/dev/null | grep '^MFA'
# 4. What the worker is doing right now (it logs every blueprint it applies).
sudo docker logs --since 5m authentik-worker 2>&1 | grep -i blueprint | cut -c1-200 | tail -8
```

Done when: check 1 shows every instance `successful` (ours included), check 2 lists `homelab-dashboard` and `homelab-traefik` (mode `forward_single`), the apps `dashboard` and
`traefik`, an outpost carrying both providers and the group `homelab-admins`, and check 3 shows `('configure', ['totp', 'webauthn'])`. Then run check 3.5 below.

**Dependency order** (our blueprint waits for these through `metaapplyblueprint`; this is also the order to use by hand):

1. `default/flow-default-authentication-flow.yaml` (Default - Authentication flow)
2. `default/flow-default-authenticator-totp-setup.yaml` and `default/flow-default-authenticator-webauthn-setup.yaml` (MFA setup flows)
3. `default/flow-default-provider-authorization-implicit-consent.yaml` and `default/flow-default-provider-invalidation.yaml` (provider flows)
4. `system/bootstrap.yaml` (authentik Bootstrap: creates `akadmin`)
5. `system/providers-oauth2.yaml`, `system/providers-proxy.yaml` and `default/flow-default-source-enrollment.yaml` (provider models and the enrolment flow that were `unknown` in M4)
6. `custom/homelab-apps.yaml` (ours, mounted at `/blueprints/custom`: MFA enforcement, group, providers, applications, embedded outpost)

**Manual fallback** if an instance is still `unknown` or `error` after ~30 minutes (the worker is healthy and the log shows no activity): apply that blueprint yourself, in the order
above, one at a time, and wait for each to return. Paths are relative to `/blueprints` inside the worker (ours is `custom/homelab-apps.yaml`). The command validates, then applies,
and several paths can be given in order (`--dry-run` only validates). It writes the objects directly, so the instance status in the UI may still say `unknown` afterwards: judge by
checks 2 and 3, not by check 1.

```bash
sudo docker exec authentik-worker ak apply_blueprint default/flow-default-authentication-flow.yaml
sudo docker exec authentik-worker ak apply_blueprint system/providers-oauth2.yaml
sudo docker exec authentik-worker ak apply_blueprint custom/homelab-apps.yaml
```

Then repeat checks 1 to 3. If one fails with a message about a missing flow or stage, a prerequisite from the list is not applied yet: apply that one first. `apply_blueprint` runs in the
foreground and may itself take several minutes on the Pi. A real `error` (not `unknown`) is a content problem: open the instance in the UI (Customization, Blueprints) for the message.

```bash
# 3.5 forward auth answers (from inside the proxy network, bypassing the allowlist, which a loopback curl on the Pi would fail with 403)
DOMAIN="$(sudo sed -n 's/^DOMAIN=//p' /apps/secrets/runtime.env)"
sudo docker exec traefik wget -S -q -O /dev/null --header "X-Forwarded-Host: traefik.$DOMAIN" --header 'X-Forwarded-Proto: https' \
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
sudo docker stop authentik-server
```

   From the laptop, with Authentik stopped, `https://traefik.<domain>/` must **not** show the dashboard (an error page, never the dashboard: forward auth fails closed). Then switch the break-glass router on (it switches itself off after 60 minutes, and a reboot removes it):

```bash
sudo scripts/breakglass.sh on 30
```

   Open `https://bg-traefik.<domain>/`: the browser asks for the break-glass user and password (from the password manager) and shows the dashboard while Authentik is down. Then:

```bash
sudo scripts/breakglass.sh off                       # remove the break-glass router again (auto-off and reboot do the same)
sudo docker start authentik-server                   # back up; https://traefik.<domain>/ redirects to the login again
```

6. **Group binding (fail-closed)**, optional on the Pi (proved in the local self-test): in the admin UI create a user without adding them to `homelab-admins`; that user can log in to
   Authentik but `https://traefik.<domain>/` shows "Permission denied". Delete the user afterwards.
7. **Headers** reach the backends on routers that use `authentik@file`: the `dashboard` host arrives in M5 (Homepage); until then the self-test proves it with a stand-in
   (`X-authentik-username`, `X-authentik-groups` are set from the session, and a forged value sent by a client is replaced).

## 6. Recovery

| Situation | What to do |
|-----------|------------|
| Lost phone, another MFA device or key still works | Log in with it, User settings, MFA Devices: delete the lost one, add a new one. |
| Lost every MFA device, or the `akadmin` password | Create a one-time recovery link (valid for the minutes you pass, here 15) from the Pi, open it, then fix the account: `sudo docker exec authentik-server ak create_recovery_key 15 akadmin` prints `/recovery/use-token/<token>/`; open `https://auth.<domain>` plus that path **within 15 minutes**. You are logged in as `akadmin`: immediately enrol a new MFA device and, if needed, set a new password (User settings). The link is single use and is not stored anywhere else. |
| Authentik is down or broken, you need the dashboard | Break-glass: `sudo scripts/breakglass.sh on 30`, browse `https://bg-traefik.<domain>/` (basic auth, rate limited, LAN or tailnet only). Stop it again with `sudo scripts/breakglass.sh off`. `sudo scripts/breakglass.sh status` and the preflight WARN tell you whether it is on; it never survives a reboot. |
| The Pi is unreachable on the network | Raspberry Pi Connect terminal (works without SSH), then the rows above. |
| Database or data directory lost (new SD card) | The blueprint rebuilds groups, applications and providers; **users and MFA devices are gone** until backups exist (a later phase). `scripts/bootstrap.sh`, set `authentik/bootstrap-password`, `sudo scripts/deploy.sh`, log in as `akadmin`, enrol MFA again. |

Authentik secret-key rotation invalidates every session and is not a routine operation; the Postgres password is changed with `ALTER USER` first, then SSM, then `deploy.sh --recreate authentik` (`rotate-secrets.md`, plan R48).

## 7. Rollback

Smallest first.

1. **Dashboard unreachable because of Authentik:** use break-glass (section 6, row 3). Nothing else changes.
2. **Stop Authentik, keep everything else:** `dc stop authentik-server authentik-worker authentik-postgresql`. The dashboard fails closed (it is not served) and `bg-traefik` still works. Data stays.
3. **Back to the M3 state (basic auth in front of the dashboard):** on the laptop `git revert` the M4 commits, push, then on the Pi `sudo scripts/deploy.sh` (a full deploy passes
   `--remove-orphans`, which removes the Authentik containers; `/apps/authentik` data stays). The M3 commit that had basic auth on the dashboard is `12fa978`.
4. **Wipe Authentik completely** (destroys users and MFA devices; only when you really want a clean start):
   `dc rm -sf authentik-server authentik-worker authentik-postgresql && sudo rm -rf /apps/authentik/data /apps/authentik/postgres && sudo scripts/bootstrap.sh`, then deploy again (section 2).

## 8. Account hygiene after the first login (SEC-L8, owner steps)

Live Authentik state cannot be audited offline, so these are checks the owner does once and after every change to flows:

1. **Named admin, then retire `akadmin`.** Create your own user, add it to `homelab-admins` and to the Authentik `authentik Admins` group, enrol MFA for it, log in as that user and
   confirm the dashboards work. Then deactivate `akadmin` (Directory, Users, `akadmin`, Deactivate) so the well-known name is not a standing superuser target. Keep the recovery path
   (`sudo docker exec authentik-server ak create_recovery_key 15 <your user>`) in mind: it works for any user.
2. **Set `authentik/bootstrap-password` back to UNSET** (`scripts/set-secret.sh --unset authentik/bootstrap-password`), then `sudo scripts/deploy.sh` so the worker no longer exports it.
3. **No second path past MFA.** The blueprint patches the stock authentication flow, so the stock flow is the only one. Check in Admin, Flows and Stages, Flows: the brand's
   authentication flow is `default-authentication-flow`; **no recovery flow is attached to the brand** (Brands, the default brand, Default flows, "Recovery flow" empty) and no
   passwordless or "WebAuthn only" authentication flow is bound anywhere. If you ever add one, it must still contain the MFA validation stage. Re-run
   `scripts/test-authentik-config.sh` (full run) after any flow change: it proves MFA enrolment is forced and an outsider is denied.
4. **Event retention.** Authentik keeps login events (with client IP and user agent) for 365 days by default. For a household, set Admin, Events, Settings, "Event retention" to 90 days
   (POPIA data-minimisation) and note the processing in your register.
5. **Break-glass drill.** At least twice a year run `sudo scripts/breakglass.sh on 10`, log in at `bg-traefik.<domain>`, then `off`. The htpasswd is bcrypt cost 12; the password lives only in the password manager.

## 9. What only the Pi can verify (everything else ran in `scripts/test-authentik-config.sh`)

arm64 behaviour and first-start duration; real owners and modes on `/apps/secrets` and `/apps/authentik` (the local run used Docker named volumes); the allowlist with a real tailnet
or LAN client in front of forward auth; the memory limits under real use (`sudo docker stats`); a browser with the staging certificate; WebAuthn; the `bg-traefik` flow with the real htpasswd.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `authentik-postgresql` restarts: `data directory ... has wrong ownership` or `Permission denied` | `/apps/authentik/postgres` must be `70:70` 0700: `sudo scripts/bootstrap.sh`. |
| `authentik-server` logs `Permission denied` on `/data` | `/apps/authentik/data` must be `10002:10002` 0700: `sudo scripts/bootstrap.sh`. |
| Server healthy, `forward auth` 404 for the app host | The embedded outpost has not loaded the providers yet (blueprint still applying: check 3.4), or the host in the request carries a port (use the standard port 443) or differs from `external_host`. |
| Login works, then `404` or a loop on `/outpost.goauthentik.io/callback` | The app host has no `<app>-outpost` router. Every host using `authentik@file` needs `Host(<app host>) && PathPrefix(/outpost.goauthentik.io/)` to service `authentik` with `lan-allowlist@file` (see the dashboard labels in `traefik/compose.yaml`). |
| `403` on the dashboard before any login | The allowlist: the client's address is not LAN/tailnet (see R49 in the plan notes: Tailscale must not SNAT). |
| `Permission denied` after a good login | The user is not in `homelab-admins` (Directory, Groups). |
| `ak create_recovery_key` fails with `KeyError: getpwuid()` | The container lost `USER=authentik` from its environment (it is set in `authentik/compose.yaml`); use `sudo docker exec -e USER=authentik ...`. |
| Secret rotated in SSM but Authentik still uses the old value | Containers keep the secret file they were created with: `sudo scripts/deploy.sh --recreate authentik` (see `rotate-secrets.md`). |
| Providers, apps or the outpost binding are missing 5 to 25 minutes after the first deploy | The worker is still applying blueprints (slow on Pi/SD): section 3.4a. Do not restart the worker; use the progress checks and, after ~30 minutes, the manual `ak apply_blueprint` fallback. |
| Blueprint shows `error` | Admin interface, Customization, Blueprints, open the instance for the message; `sudo docker logs authentik-worker 2>&1 | grep -i blueprint`. |
