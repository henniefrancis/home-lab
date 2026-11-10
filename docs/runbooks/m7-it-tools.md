# Runbook: M7 IT Tools at `tools.${DOMAIN}`, behind Authentik

Plan: R17 build plan (owner-approved 2026-11-10; vault `Architecture/R17 build plan.md`), milestone M7. Self-test: `scripts/test-it-tools-config.sh` (CI runs the full test:
static checks, image build, the real Traefik routers with a stub outpost). Prerequisite: M4 and M5 are deployed.

Everything below runs **on the Pi** in the repo checkout (`/opt/home-lab`) unless it says **[Owner, browser]**. `DOMAIN` is read from the root-only `runtime.env`.

## What M7 deploys

| Container | Image | Role |
|-----------|-------|------|
| `it-tools` | `home-lab/it-tools:2024.10.22-7ca5933`, **built on the Pi** from `it-tools/Dockerfile` | IT Tools static site, `proxy` network only, no published port, uid 10005, read-only root, 64M |

- **Why a local build:** the only upstream release (official `ghcr.io/corentinth/it-tools`, 2024-10-22) runs on Alpine 3.20.3, which is end of life, with 3 CRITICAL and 37 HIGH CVEs
  (trivy, 2026-11-10). The app has no server side, so `it-tools/Dockerfile` copies the 282 official static files onto the official, current `nginxinc/nginx-unprivileged`
  stable alpine-slim image. Both `FROM` lines are digest-pinned and nothing is downloaded at build time (the N8 rule of `ra-helper`). Dependabot proposes new digests for both.
- **NGINX** starts directly (`ENTRYPOINT nginx -g 'daemon off;'`), so no image entrypoint script rewrites the committed `it-tools/nginx.conf`. It listens on 8080 inside the proxy
  network, hides its version, refuses dot files and answers every tool route with `index.html` (single-page app).
- **Privacy:** the official build has its Plausible tracker switched off, and the site sends `Content-Security-Policy: connect-src 'self'`, so the page cannot call any other host.
- **Routers** (`traefik/dynamic/routers.yml`): `it-tools` = `Host(tools.${DOMAIN})` with `lan-allowlist`, then `authentik`, and `it-tools-outpost` for the login callback.
  That is the same pattern as the dashboard.
- **Authentik** (blueprint `authentik/blueprints/homelab-apps.yaml`): provider `homelab-it-tools` (forward_single, host-only cookie), application `it-tools` bound to
  `homelab-admins`, added to the embedded outpost. **This is a blueprint change**, and on the Pi the worker re-applies it slowly. Allow up to about 25 minutes ([[m4-authentik]]
  section 3.4a) before testing in the browser.
- **Homepage:** the IT Tools tile moves from "Coming soon" to a new "Tools" group.

## 1. Before you start

- Nothing to set in SSM: IT Tools has no secrets.
- `config/lab.env` gains `ITTOOLS_UID=10005` / `ITTOOLS_GID=10005` (committed). No directory under `/apps` is needed (the app owns no data).

## 2. Deploy

```bash
cd /opt/home-lab
sudo scripts/deploy.sh
```

This fetches the repo, verifies the commit signature, **builds** `home-lab/it-tools` (a few seconds: two pinned images are pulled and one directory is copied; no package
download), copies the routers into `/apps/traefik/dynamic` (Traefik picks them up within seconds) and starts `it-tools`. Authentik notices the changed blueprint by itself.

## 3. Verify (all read-only)

```bash
# 3.1 healthy, identity, hardening
sudo docker compose -p home-lab ps it-tools                                  # Up ... (healthy)
sudo docker exec it-tools sh -c 'for p in /proc/[0-9]*/status; do awk "/^Uid:/{print \$2}" $p; done | sort -u'   # 10005
sudo docker inspect it-tools -f '{{.HostConfig.ReadonlyRootfs}} {{json .HostConfig.CapDrop}} {{len .HostConfig.PortBindings}} {{len .Mounts}}'  # true ["ALL"] 0 0

# 3.2 forward auth answers for tools.<domain>: an anonymous request is sent to the Authentik login
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://tools.$(sudo grep -oP '^DOMAIN=\K.*' /apps/secrets/runtime.env)/   # 302 https://auth.../application/o/authorize/...

# 3.3 the blueprint is applied: provider and application exist, the outpost serves the provider
sudo docker exec authentik-server ak shell -c "from authentik.providers.proxy.models import ProxyProvider as P; from authentik.outposts.models import Outpost as O; print(sorted(p.name for p in P.objects.all())); print([sorted(p.name for p in o.providers.all()) for o in O.objects.filter(managed='goauthentik.io/outposts/embedded')])" 2>&1 | tail -2
# expect homelab-it-tools in both lists; if it is missing, wait (section 3.4a of m4-authentik.md), do not restart the worker
```

First deploy (2026-11-10): the worker started re-applying the blueprint at 16:16 UTC by itself and finished at 16:41, 25 minutes later. Until then `tools.` answered the
outpost's 404 page (about 5.8 KB; Traefik's own 404 is 19 bytes). Do not start `ak apply_blueprint` while that runs: it only queues behind it (m4-authentik.md 3.4a).

## 4. Browser check [Owner, browser]

1. Open `https://tools.<domain>`: you are sent to the Authentik login (or straight in if your session is fresh), then IT Tools loads.
2. Open any tool (for example *Base64 string encoder/decoder*). It works offline in the browser.
3. Open `https://dashboard.<domain>`: the IT Tools tile is in the "Tools" group and opens the app.
4. Optional: in the browser's developer tools, Network tab, the page makes no request to any host other than `tools.<domain>`.

## 5. Rollback

- **Stop the app:** `sudo docker compose -p home-lab stop it-tools`. With no backend Traefik answers 502 for `tools.` and nothing else is affected.
- **Undo the milestone:** make a signed revert commit of the M7 changes (it removes the include, the routers, the blueprint entries and the tile), push it, wait for CI, then run
  `sudo scripts/deploy.sh` and `sudo docker rm -f it-tools`. Authentik keeps the provider and application after the blueprint entry is gone. Delete them under Admin,
  Applications and Admin, Providers, or leave them: they protect nothing once the router is gone.

## 6. What only the Pi can verify (everything else ran in `scripts/test-it-tools-config.sh`)

- The arm64 build on the Pi (CI builds amd64; both bases publish arm64).
- The real Authentik login and MFA for the new provider (the self-test uses a stub outpost).
- The Homepage tile in the real dashboard.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `tools.` answers 404 | Traefik has not loaded the new routers: `sudo ls /apps/traefik/dynamic` should list `routers.yml` with the `it-tools` router; re-run `sudo scripts/deploy.sh`. |
| `tools.` answers 500 or 502 after login | The provider is not applied yet (section 3.3), or the container is down (`sudo docker logs it-tools`). |
| Login loop on `tools.` | The `it-tools-outpost` router is missing or the provider is not in the embedded outpost (section 3.3). |
| `deploy.sh` fails at the build | It needs network access to pull the two pinned base images. `--offline` uses the image that is already built. |
