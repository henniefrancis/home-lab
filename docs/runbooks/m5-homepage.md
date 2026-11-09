# Runbook: M5 Homepage dashboard at `dashboard.${DOMAIN}`, behind Authentik

Plan: `docs/plan/phase-1-traefik.md` rev 7 (section 6.6, milestone M5) plus "M5 implementation notes" at its end. Self-test: `scripts/test-homepage-config.sh`
(`--static` is what CI runs). Prerequisite: M4 is deployed and the Authentik blueprint is fully applied ([[m4-authentik]] section 3.4a).

Everything below runs **on the Pi** in the repo checkout (`/opt/home-lab`) unless it says **[Owner, browser]**. `DOMAIN` is read from the root-only `runtime.env`, so
the real domain is never typed into this runbook or git.

## What M5 deploys

| Container | Image | Role |
|-----------|-------|------|
| `homepage` | `ghcr.io/gethomepage/homepage:v2.7.0@sha256:...` (digest-pinned; arm64 verified in the manifest) | Dashboard, `proxy` network only, no published port, uid 10003, read-only root, 384M |

- Routers (file provider, `traefik/dynamic/routers.yml`; the container has no Traefik labels): `homepage` = `Host(dashboard.${DOMAIN})` with `lan-allowlist@file,authentik@file`, and
  `homepage-outpost` = the same host plus `PathPrefix(/outpost.goauthentik.io/)` to the Authentik service (priority 100, allowlist only), exactly like the Traefik dashboard.
  The Authentik provider `homelab-dashboard` and application `dashboard` (group `homelab-admins`) already exist in the M4 blueprint: **M5 changes no blueprint**, so nothing
  new has to be applied by the Authentik worker.
- Config is committed in `homepage/config/` and mounted read-only. The domain comes from `HOMEPAGE_VAR_DOMAIN` (`{{HOMEPAGE_VAR_DOMAIN}}` in the YAML). Live tiles: Traefik and
  Authentik. "Coming soon" tiles (links work once the service exists): Home Assistant (`ha.`), IT Tools (`tools.`), Linkwarden (`links.`), Netdata (`netdata.`), Pi-hole
  (`pihole.`), Portainer (`portainer.`). The Homepage update check and version display are off; Homepage has no telemetry. Logs go to stdout (`sudo docker logs homepage`), never
  into the checkout.
- **No Docker integration at all (decision 2026-11-08, SEC-H2).** The status dots on the live tiles needed Homepage to read the Docker API, and the socket proxy that provided it
  (`tecnativa/docker-socket-proxy:v0.5.0`, `CONTAINERS=1`) allows reading `/containers/{id}/archive`, `/export`, `/logs` and `/top` (reported as CVE-2026-78122, no fixed
  release): anything with proxy access can read files and logs of every container. The proxy and the optional add-on (`compose.docker-status.yaml`) were REMOVED, not kept
  as an option, and the tiles are plain links. A strict allow-list proxy (only `GET /containers/json` and `/containers/{id}/json`) was considered and not built: the
  gain (a status dot) does not justify a new component with access to the Docker API on a host whose threat model is a Traefik or Authentik compromise. Revisit only with a
  proxy that is maintained and has no archive, export, logs or exec path.

## 1. Before you start

```bash
cd /opt/home-lab
sudo git -C /opt/home-lab status --short   # expect nothing (the checkout is root-owned: plain git says "dubious ownership")
sudo scripts/deploy.sh --only tailscale   # brings the checkout to the latest SIGNED release (never git pull: it would skip the signature check)
sudo scripts/preflight.sh --stage bootstrap | grep -E 'svc-id|FAIL'     # six svc-id lines now include HOMEPAGE_UID and HOMEPAGE_GID: all PASS
getent passwd 10003 || echo "id 10003 is not a host user (expected)"
sudo docker ps --format '{{.Names}} {{.Status}}' | grep -E 'traefik|authentik-server'     # both Up, authentik-server healthy
```

`bootstrap.sh` needs no re-run for M5: Homepage owns no directory under `/apps` (the config comes from the checkout, read-only).

## 2. Deploy

```bash
cd /opt/home-lab
sudo scripts/deploy.sh --only homepage
```

This fetches the repo and verifies the commit signature (`m2-pi-setup.md` 3.1), refreshes secrets (no Homepage secret is needed), pulls the image (about 250 MB, arm64) and starts only `homepage`; Traefik and Authentik are not
touched. `deploy.sh` also copies the routers into `/apps/traefik/dynamic`, and Traefik's file provider picks them up within a few seconds (no restart).

## 3. Verify

```bash
# 3.1 healthy, identity, hardening
sudo docker inspect homepage --format 'health={{.State.Health.Status}} user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{.HostConfig.CapDrop}} ports={{len .HostConfig.PortBindings}} mem={{.HostConfig.Memory}}'
sudo docker exec homepage id                                       # uid=10003 gid=10003
sudo docker inspect homepage --format '{{range .Mounts}}{{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}'   # only .../homepage/config -> /app/config rw=false
sudo docker inspect homepage --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'                # proxy only
sudo docker exec homepage sh -c 'touch /app/x' 2>&1 | tail -1     # Read-only file system
sudo docker logs --tail 15 homepage 2>&1 | cut -c1-160           # "Ready"; no EROFS/EACCES; no Docker errors
```

Expected: `health=healthy user=10003:10003 readonly=true capdrop=[ALL] ports=0 mem=402653184`; the only mount is the config, read-only; network `proxy` only.
(The first start takes up to a minute on the Pi while Next.js warms up; the container healthcheck is the image's.)

```bash
# 3.2 Homepage itself refuses other hosts (HOMEPAGE_ALLOWED_HOSTS): 200 for the dashboard host, 400 for anything else
DOMAIN="$(sudo sed -n 's/^DOMAIN=//p' /apps/secrets/runtime.env)"
for h in "dashboard.$DOMAIN" evil.example.test; do
  printf '%s -> ' "$h"; sudo docker exec homepage wget -S -qO /dev/null --header "Host: $h" http://127.0.0.1:3000/api/services 2>&1 | awk '/^ *HTTP\//{c=$2} END{print c}'
done

# 3.3 forward auth answers for the dashboard host (from inside the proxy network, bypassing the allowlist)
sudo docker exec traefik wget -S -q -O /dev/null --header "X-Forwarded-Host: dashboard.$DOMAIN" --header 'X-Forwarded-Proto: https' \
  --header 'X-Forwarded-Uri: /' http://authentik-server:9000/outpost.goauthentik.io/auth/traefik 2>&1 | grep -iE 'HTTP/|location' | cut -c1-120

# 3.4 Traefik sees both routers and no error about them
sudo docker logs --since 10m traefik 2>&1 | jq -R -r 'fromjson? | select(.level=="error") | .msg' | grep -Ei 'homepage|dashboard' || echo "no router errors"
```

Expected: `evil... -> 400` and `dashboard... -> 200`; `HTTP/1.1 302 Found` with `location: https://auth.<domain>/application/o/authorize/?client_id=...` (the `wget: bad address`
that follows is BusyBox trying to follow the redirect; ignore it); `no router errors`. A `404` in 3.3 means the outpost has not loaded the `dashboard` provider: [[m4-authentik]]
section 3.4a. Because forward auth is fail-closed, nothing of Homepage is reachable until 3.3 returns 302.

## 4. Browser check [Owner, browser]

On the LAN or the tailnet (the allowlist), in a private window. The staging certificate is not trusted: accept the warning (it is the Let's Encrypt STAGING CA until M6).

1. Open `https://dashboard.<your domain>/`. Expect an immediate redirect to the Authentik login on `auth.<domain>` (no Homepage content flashes first).
2. Log in as `akadmin` with the password and your TOTP code. Expect to land on the Homepage dashboard: group **Platform** (Traefik, Authentik) and group **Coming soon** (six tiles),
   a resources widget and the clock. The tiles have no status dot (Docker integration is off, see above).
3. Click the Traefik tile: `traefik.<domain>` shows the Traefik dashboard. Because each app has its own host-only session cookie it goes through one more redirect to
   Authentik, but without asking for the password again.
4. Developer tools, Application, Cookies: on `dashboard.<domain>` there is one `authentik_proxy_...` cookie with no Domain (host-only), HttpOnly, Secure.
5. `https://<your domain>/` and `https://www.<your domain>/` must **not** show anything from the Pi (connection refused at TLS, or a 404): the apex and `www` are not served.
6. Log out of Authentik (`auth.<domain>`, user menu) and reload the dashboard: back at the login.

## 5. Optional

**Container status dots: removed.** See the decision in "What M5 deploys"; there is no switch to turn them back on.

**Authentik widget (needs the optional SSM parameter `homepage/authentik-token`).** Not enabled in the committed config, because an unset token must not leave a broken tile.
To add it later: create a read-only Authentik API token for a service account (Directory, Tokens), `scripts/set-secret.sh homepage/authentik-token`, `sudo scripts/deploy.sh`
(the file appears as `/apps/secrets/homepage/authentik-token`, 10003:10003 0400), then in a commit add to `homepage/compose.yaml`
`secrets: [authentik_token]` and `HOMEPAGE_FILE_AUTHENTIK_TOKEN: /run/secrets/authentik_token` (top-level secret `file: ${APPS_ROOT}/secrets/homepage/authentik-token`), and to the
Authentik tile in `homepage/config/services.yaml`:

```yaml
        widget:
          type: authentik
          url: http://authentik-server:9000
          key: "{{HOMEPAGE_FILE_AUTHENTIK_TOKEN}}"
```

(Internal URL on the proxy network, so it does not go through the allowlist.) Update `scripts/test-homepage-config.sh` in the same commit: it asserts that no `HOMEPAGE_FILE_` is in the committed config.

## 6. Rollback

```bash
cd /opt/home-lab
sudo docker rm -f homepage          # removes only Homepage; Traefik, Authentik and the Traefik dashboard keep working
```

To keep it from coming back on the next full deploy, on the laptop `git revert` the M5 commits and push, then `sudo scripts/deploy.sh` on the Pi (a full deploy passes
`--remove-orphans`). Nothing else holds state: there is no Homepage volume, secret or Authentik change to undo. `dashboard.<domain>` then answers 404 (no router).

## 7. What only the Pi can verify (everything else ran in `scripts/test-homepage-config.sh`)

arm64 start time and memory under real use (`sudo docker stats homepage`, limit 384M); the real Authentik outpost answering for `dashboard.<domain>` (the test uses a stub for it;
the real chain is covered by `scripts/test-authentik-config.sh` with a stand-in app); the allowlist with a real LAN or tailnet client; a browser with the staging
certificate; real owners (`getent passwd 10003` empty).

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `403` on `dashboard.<domain>` before any login | The allowlist: the client is not on the LAN or tailnet (plan note R49: Tailscale must not SNAT). |
| `404` on `dashboard.<domain>` | No router matched: `/apps/traefik/dynamic/routers.yml` is missing or stale (run `sudo scripts/deploy.sh --only traefik`), or `DOMAIN` is not set in the Traefik container. A running but unhealthy `homepage` gives `502`/`503`, not 404. |
| `421 Misdirected Request` on `dashboard.<domain>` while `auth.<domain>` works | The browser reuses an old HTTP/2 connection opened to another host of the same wildcard certificate before this router existed. Close the browser or flush its socket pools (`chrome://net-internals/#sockets`) and reload; fresh connections work. Traefik now has a single TLS option set, so option names cannot differ between hosts. |
| Login works, then `404` or a loop on `/outpost.goauthentik.io/callback` | The `homepage-outpost` router is missing: `grep -c homepage-outpost /apps/traefik/dynamic/routers.yml` must print 1; redeploy with `sudo scripts/deploy.sh --only traefik`. |
| `500` or `502` on the dashboard | Authentik is down or not healthy (forward auth fails closed). Use `bg-traefik` (m4 runbook, break-glass) for the Traefik dashboard; Homepage has no break-glass by design. |
| `Permission denied` after a good login | The user is not in `homelab-admins` (Authentik, Directory, Groups). |
| Page says `Host validation failed` (400) | The browser used a host other than `dashboard.<domain>` (an IP or another name). Use the dashboard host name. |
| Homepage restarts with `Failed to initialize required config` | A config file is missing from `homepage/config/` (all nine must exist; the mount is read-only so Homepage cannot create them). `git status` in the checkout. |
| `EACCES` writing `/app/.next/cache` | The tmpfs lost its `uid=10003,gid=10003` options (`homepage/compose.yaml`); recreate with `deploy.sh --only homepage`. |
| Tiles show `{{HOMEPAGE_VAR_DOMAIN}}` or a blank host | `HOMEPAGE_VAR_DOMAIN` is empty: `runtime.env` has no `DOMAIN`; `sudo scripts/fetch-secrets.sh` and redeploy. |
