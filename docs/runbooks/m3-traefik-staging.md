# Runbook: M3 Traefik + ra-helper + socket proxy on the Let's Encrypt STAGING CA

Plan: `docs/plan/phase-1-traefik.md` rev 7 (sections 6.1-6.3, 6.5, milestone M3). Milestone M3 is done when the checks in "Verify" are green and the
staging wildcard `*.${DOMAIN}` is in `/apps/traefik/letsencrypt/acme-staging.json`. Production certificates are M6; nothing here talks to the
production CA.

Everything below runs **on the Pi** in the Raspberry Pi Connect terminal, in the repo checkout, unless it says **[Laptop]**. Do not paste secret
values anywhere. `DOMAIN` is read from the root-only `runtime.env`, so the real domain is never typed into this runbook or git.

## What M3 deploys

| Container | Image | Role |
|-----------|-------|------|
| `socket-proxy` | `tecnativa/docker-socket-proxy:v0.5.0` | read-only Docker API for Traefik (`CONTAINERS`, `EVENTS`, `VERSION`, `PING`; `POST=0`), internal network only |
| `traefik` | `traefik:v3.7.17` | ports 80 and 443 only; wildcard cert via DNS-01 on the **staging** CA; dashboard at `traefik.${DOMAIN}` |
| `ra-helper` | `home-lab/ra-helper:1.8.6` (built on the Pi) | `aws_signing_helper serve` on `127.0.0.1:9911` inside Traefik's network namespace; the **only** container that gets `traefik.key` |
| `tailscale` | `tailscale/tailscale:v1.104.4` | now part of the root project; F01 fix (below) |
| `breakglass` | `traefik/whoami:v1.12.0` | optional profile that holds the `bg-traefik` router; **not started** in M3 |

**Dashboard in M3 (decision per plan 6.2):** it is enabled and protected by the LAN/tailnet allowlist (`10.0.0.0/24`, `100.64.0.0/10`) **plus** HTTP
basic auth with the break-glass htpasswd line from SSM (`/apps/secrets/traefik/breakglass-htpasswd`). It is not open to anyone outside the allowlist
and not open without a password. M4 replaces the basic auth with Authentik (`authentik@file`); the `breakglass` profile then keeps a basic-auth path.

## Deviations and findings (read once)

- **HTTP redirect is 301 for GET/HEAD and 308 for every other method.** Traefik v3.7's entrypoint redirection has no status-code option; `permanent=true`
  gives 301 for GET and 308 for POST and friends (verified on the pinned image). Both are permanent and keep the method safe.
- **Unmatched hosts get a bare 404** without the security headers (entrypoint middlewares apply to routers). Every real lab router has them.
- **`default` TLS option is overridden** (same strict settings as `modern`): Traefik uses it for names that match no router (the apex, no SNI), which would
  otherwise be served the self-generated default certificate. Tested: the apex and no-SNI handshakes are refused.
- Extra flags beyond the plan: `--global.aliasHeadersStrategy=delete` (silences a v3.7 warning and blocks header-alias spoofing before M4 forward auth),
  `--certificatesresolvers.le.acme.keyType=EC256` (the default RSA 4096 is slow on a Pi), and a loopback-only `ping` entrypoint (127.0.0.1:8082) so the
  default `:8080` entrypoint never exists.
- **ACME email is not needed.** Traefik v3.7.17 (lego v5) registered an account with an empty email against a local test CA (Pebble). A10 is closed;
  no `/home-lab/traefik/acme-email` parameter is created.
- `aws_signing_helper` is **1.8.6** everywhere (plan text said 1.8.5). 1.8.6 rejects mismatched `Host` headers and exits at start if it cannot get
  credentials, so `ra-helper` restarts until AWS is reachable and the certificate is valid.
- The Traefik access log goes to `/apps/traefik/logs/access.log` (plan) and is not rotated. Fine for weeks on a quiet lab; add logrotate before it matters.
- Plan item Q14 is not defined in the rev 7 text (it points to rev 6); M3 is verified against the acceptance list in plan section 8 and S2/S17 below.

## F01: Tailscale `modprobe: can't change directory to '/lib/modules'`

Cause: with kernel networking (`TS_USERSPACE=false`) Tailscale programmed its firewall chains with the container's `iptables`, which tries to `modprobe ip_tables`
inside the container, and the container has no `/lib/modules`. Fix: `TS_DEBUG_FIREWALL_MODE=nftables` in `tailscale/compose.yaml`. Tailscale's
firewall-mode documentation describes this setting; nftables mode talks netlink to the kernel and never calls `iptables` or `modprobe`. `NET_ADMIN` is already
present, so no new capability, no `CAP_SYS_MODULE`, no `/lib/modules` mount and no host change. (Trade-off: Tailscale documents the variable as a debug setting that may
change; the `router:` log lines show which mode is in effect.)
Fallback if the Pi's kernel lacks nf_tables (unlikely on Debian 13): drop the variable and preload the legacy modules on the host instead:
`printf 'ip_tables\niptable_filter\nip6table_filter\n' | sudo tee /etc/modules-load.d/home-lab-netfilter.conf && sudo modprobe -a ip_tables iptable_filter ip6table_filter`.

## 1. Before you start

```bash
cd /opt/home-lab
git status --short            # expect nothing
sudo scripts/preflight.sh --stage bootstrap | tail -15
sudo test -s /apps/secrets/traefik/breakglass-htpasswd && echo "break-glass htpasswd present"
sudo ls -l /etc/home-lab/pki/traefik.key /etc/home-lab/pki/traefik.crt
sudo sed -n 's/^\(DOMAIN\|ROUTE53_ZONE_ID\|RA_[A-Z_]*\)=.*/\1 is set/p' /apps/secrets/runtime.env
```

Expected: preflight without FAIL, the htpasswd line present, `traefik.key` `10001:10001 0400`, all six names reported as set (values stay hidden).

## 2. Deploy

The M2 Tailscale container was created under a different compose project, so Docker would refuse to create a second container named `tailscale`. Remove
the old container once (its state lives in `/apps/tailscale/state`, so the node stays joined; the tailnet drops for about ten seconds):

```bash
cd /opt/home-lab
sudo docker rm -f tailscale
sudo scripts/deploy.sh
```

`deploy.sh` pulls the repo, fetches secrets from SSM, pulls the images, builds `ra-helper` (needs `deb.debian.org` and `rolesanywhere.amazonaws.com`;
the build fails if the binary checksum is wrong) and starts everything. Wait about two minutes for the first DNS-01 issuance.

```bash
sudo docker compose -p home-lab -f compose.yaml --env-file config/lab.env --env-file /apps/secrets/runtime.env ps --format 'table {{.Name}}\t{{.Status}}'
```

Expected: `socket-proxy` Up, `traefik` Up (healthy), `ra-helper` Up (healthy), `tailscale` Up.

## 3. Verify

```bash
DOMAIN="$(sudo sed -n 's/^DOMAIN=//p' /apps/secrets/runtime.env)"
```

### 3.1 ra-helper and credentials

```bash
docker logs --tail 15 ra-helper                       # no "failed to generate initial credentials"
docker logs traefik 2>&1 | grep -c 'no EC2 IMDS role' # 0
```

### 3.2 The staging wildcard was issued (acceptance 1)

```bash
docker logs traefik 2>&1 | grep -iE 'acme|certificate|dns01' | tail -12
sudo jq -r '.le.Certificates[] | "main=\(.domain.main) sans=\(.domain.sans // [] | length)"' /apps/traefik/letsencrypt/acme-staging.json
echo | openssl s_client -connect 127.0.0.1:443 -servername "traefik.$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject -ext subjectAltName -dates
```

Expected: `main=*.<your domain> sans=0`; the issuer contains **`(STAGING)`** (for example `O=(STAGING) Let's Encrypt`); the SAN list has the wildcard only and **no
apex**; `notAfter` about 90 days away. A browser will warn that the certificate is not trusted: that is correct for staging.
The file `acme-production.json` must not exist yet: `sudo ls /apps/traefik/letsencrypt/`.

### 3.3 Redirect, TLS, headers

```bash
curl -si -X POST -H "Host: traefik.$DOMAIN" http://127.0.0.1/ | head -1       # HTTP/1.1 308 Permanent Redirect
curl -si -H "Host: traefik.$DOMAIN" http://127.0.0.1/ | head -1               # HTTP/1.1 301 Moved Permanently
echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>&1 | grep -ci 'alert'         # 1 or more: the apex is refused
echo | openssl s_client -connect 127.0.0.1:443 -servername "traefik.$DOMAIN" -tls1_1 2>&1 | grep -c 'Protocol *: TLSv1.1'  # 0
curl -skI --resolve "traefik.$DOMAIN:443:127.0.0.1" "https://traefik.$DOMAIN/" | tr -d '\r' | grep -iE '^HTTP|^strict|^x-|^referrer|^permissions|^server'
```

The last command runs from the Pi itself, so Traefik sees a Docker bridge address and answers **403** (allowlist). That is expected here and shows the security
headers: `Strict-Transport-Security: max-age=300; includeSubDomains`, `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`,
`Permissions-Policy`, `X-Robots-Tag`, and no `Server` value.

### 3.4 Dashboard from the LAN and from the tailnet **[Laptop]**

The laptop needs name resolution until Pi-hole exists: be on Tailscale (the wildcard A record resolves to the tailnet IP), or add
`<pi-lan-ip> traefik.<your domain>` to the hosts file.

1. Open `https://traefik.<your domain>/`. Accept the staging-certificate warning (staging only).
2. A basic-auth prompt appears. Wrong password: stays 401. Username and password are the ones you generated for `traefik/breakglass-htpasswd`
   (the plaintext is in the password manager). Correct: the Traefik dashboard loads, with routers `dashboard@docker`.
3. From a device outside the LAN and tailnet (phone on mobile data, Tailscale off): the page must not load (the name resolves to a tailnet address that is
   unreachable). There are no port-forwards.

### 3.5 Hardening and isolation (S2, S17)

```bash
sudo ss -tlnp | grep -E ':(80|443|8080|8082|2375|9911)\b'                  # docker-proxy on 80 and 443 only
docker inspect traefik --format '{{json .Mounts}}' | grep -c docker.sock   # 0
docker inspect socket-proxy --format '{{range .Mounts}}{{.Destination}} rw={{.RW}}{{"\n"}}{{end}}'   # /var/run/docker.sock rw=false
docker exec traefik wget -qO- http://socket-proxy:2375/_ping; echo                                 # OK
docker exec traefik wget -S -qO- --post-data= http://socket-proxy:2375/containers/create 2>&1 | head -2   # 403
docker exec traefik wget -S -qO- http://socket-proxy:2375/images/json 2>&1 | head -2                      # 403
docker inspect traefik ra-helper --format '{{.Name}}: {{range .Mounts}}{{.Source}} {{end}}' | grep -c 'host.key'   # 0
docker inspect ra-helper --format '{{range .Mounts}}{{.Destination}} {{end}}'                      # /run/secrets/ra_acme_crt /run/secrets/ra_acme_key
docker inspect traefik --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -ciE 'SECRET|TOKEN|ACCESS_KEY|PASSWORD'   # 0
docker inspect traefik --format '{{range .Config.Cmd}}{{println .}}{{end}}' | grep -ciE 'insecure=true|api.debug|insecureSkipVerify|:8080'  # 0
```

On the Pi the `ss` line may also list Tailscale or other host listeners on unrelated ports; what matters is that nothing from Docker listens on 8080, 8082
(that one is loopback inside the container only) or 2375.

### 3.6 Tailscale F01

```bash
docker logs tailscale 2>&1 | grep -ciE "modprobe|can't change directory"           # 0 for lines after this restart
docker logs tailscale 2>&1 | grep -iE 'router:' | tail -3                          # shows nftables
docker exec tailscale tailscale --socket=/tmp/tailscaled.sock status | head -3     # node still joined, same tailnet IP
```

If the old error text is still in `docker logs` it is from before the recreate: judge only by lines after the container's new start time
(`docker inspect tailscale --format '{{.State.StartedAt}}'`).

## 4. Roll back

Stop the M3 stack only (secrets, networks and Tailscale stay):

```bash
cd /opt/home-lab
sudo docker compose -p home-lab -f compose.yaml --env-file config/lab.env --env-file /apps/secrets/runtime.env rm -sf traefik ra-helper socket-proxy breakglass
```

That returns the Pi to the M2 state (Tailscale running, no ingress). The F01 change is independent; to undo it, remove the `TS_DEBUG_FIREWALL_MODE` line and run
`sudo scripts/deploy.sh --only tailscale`.

Force a fresh staging issuance (safe: staging only; never delete the production file the same way after M6):

```bash
sudo docker compose -p home-lab -f compose.yaml --env-file config/lab.env --env-file /apps/secrets/runtime.env stop traefik
sudo rm -f /apps/traefik/letsencrypt/acme-staging.json
sudo scripts/deploy.sh --only traefik
```

## 5. Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| `ra-helper` restarts, log: `CreateSession ... 403` or `Invalid or empty profile` | wrong `RA_ACME_*` values in `runtime.env` (re-run `sudo scripts/fetch-secrets.sh`), certificate expired, or `pki_generation` bumped without reissuing the certs (`sudo scripts/cert-expiry.sh`) |
| ra-helper log: cannot read the private key | `traefik.key` is not `10001:10001 0400` (`sudo scripts/preflight.sh --stage bootstrap`) |
| Traefik log: `no EC2 IMDS role found ... 127.0.0.1:9911` | ra-helper is down or lost Traefik's network namespace after a Traefik recreate: `sudo docker compose -p home-lab -f compose.yaml --env-file config/lab.env --env-file /apps/secrets/runtime.env up -d --force-recreate traefik ra-helper` |
| Log: `AccessDenied` on `ChangeResourceRecordSets` | the ACME role only changes `_acme-challenge.<domain>` TXT: check `AWS_HOSTED_ZONE_ID` (= `ROUTE53_ZONE_ID`) is the zone of `DOMAIN` |
| DNS-01 timeout or `NXDOMAIN` | Route 53 propagation is slow; wait and restart Traefik (`docker restart traefik`, the helper keeps running); resolvers are 1.1.1.1 and 8.8.8.8 and must be reachable from the Pi |
| Traefik exits at start | an unknown flag or a bad dynamic file: `docker logs traefik`; `bash scripts/test-traefik-config.sh` reproduces it off the Pi |
| 403 from the laptop | the laptop is outside `10.0.0.0/24` and `100.64.0.0/10` (Wi-Fi guest network, VPN) |
| Port 80 or 443 already in use | another service on the Pi; `sudo ss -tlnp` |

## 6. Off-Pi checks (already run before this milestone was handed over)

`docker compose config` with dummy values for the root project; `scripts/test-traefik-config.sh` (runs the pinned Traefik image with the exact flags and the dynamic files:
healthcheck, no `:8080`, 308/301, TLS 1.1 and apex refused, allowlist 403 with headers, socket and key mount rules); the arm64 `ra-helper` image build with its
checksum; a Pebble (local test CA) run that proved the ACME account registers without an email and that lego's Route 53 provider takes credentials from
`127.0.0.1:9911` and the pinned zone ID. Only the real Roles Anywhere to Route 53 to staging CA path needs the Pi.
