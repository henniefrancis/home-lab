# Runbook: M3 Traefik + ra-helper on the Let's Encrypt STAGING CA

Plan: `docs/plan/phase-1-traefik.md` rev 7 (sections 6.1-6.3, 6.5, milestone M3). Milestone M3 is done when the checks in "Verify" are green and the
staging wildcard `*.${DOMAIN}` is in `/apps/traefik/letsencrypt/acme-staging.json`. Production certificates are M6; nothing here talks to the
production CA.

> **Security remediation (2026-11-08, SEC-H2 and friends).** The Docker socket proxy is gone: Traefik has no Docker provider and nothing mounts `docker.sock`. All routers,
> services and middlewares are files in `traefik/dynamic/` (`routers.yml`, `middlewares.yml`, `tls.yml`), which `scripts/deploy.sh` copies (root-owned) into
> `/apps/traefik/dynamic`, the directory Traefik watches. Traefik runs as uid 10004 (non-root), publishes IPv4 only, and every image is pinned by digest. The break-glass
> router is a drop-in file that `scripts/breakglass.sh on` creates (see `m4-authentik.md`). Wherever this runbook still says `socket-proxy` or `@docker`, read the file provider.

Everything below runs **on the Pi** in the Raspberry Pi Connect terminal, in the repo checkout, unless it says **[Laptop]**. Do not paste secret
values anywhere. `DOMAIN` is read from the root-only `runtime.env`, so the real domain is never typed into this runbook or git.

## What M3 deploys

| Container | Image | Role |
|-----------|-------|------|
| `traefik` | `traefik:v3.7.17@sha256:...` | non-root (10004), ports 80 and 443 only (IPv4); wildcard cert via DNS-01 on the **staging** CA; dashboard at `traefik.${DOMAIN}` |
| `ra-helper` | `home-lab/ra-helper:1.8.6` (built on the Pi) | `aws_signing_helper serve` on `127.0.0.1:9911` inside Traefik's network namespace; the **only** container that gets `traefik.key` |
| `tailscale` | `tailscale/tailscale:v1.104.4` | now part of the root project; F01 fix (below) |

**Dashboard in M3 (decision per plan 6.2):** it is enabled and protected by the LAN/tailnet allowlist (`10.0.0.0/24`, `100.64.0.0/10`) **plus** HTTP
basic auth with the break-glass htpasswd line from SSM (`/apps/secrets/traefik/breakglass-htpasswd`). It is not open to anyone outside the allowlist
and not open without a password. M4 replaces the basic auth with Authentik (`authentik@file`); the break-glass drop-in (`scripts/breakglass.sh on`) then keeps a basic-auth path.

## Deviations and findings (read once)

- **HTTP redirect is 301 for GET/HEAD and 308 for every other method.** Traefik v3.7's entrypoint redirection has no status-code option; `permanent=true`
  gives 301 for GET and 308 for POST and friends (verified on the pinned image). Both are permanent and keep the method safe.
- **Unmatched hosts get a bare 404** without the security headers (entrypoint middlewares apply to routers). Every real lab router has them.
- **One TLS option set, named `default`** (`traefik/dynamic/tls.yml`): Traefik uses it for every router and for names that match no router (the apex, no SNI), which would
  otherwise be served the self-generated default certificate. Tested: the apex and no-SNI handshakes are refused. A second named set caused HTTP 421 in M5 (see Troubleshooting).
- Extra flags beyond the plan: `--global.aliasHeadersStrategy=delete` (silences a v3.7 warning and blocks header-alias spoofing before M4 forward auth)
  and `--certificatesresolvers.le.acme.keyType=EC256` (the default RSA 4096 is slow on a Pi). There is no `ping` endpoint and no `:8080` entrypoint: the
  container healthcheck is a TCP connect to port 80 (`nc -z`), because with the access log covering internal routers every ping probe would be logged.
- **ACME email is not needed.** Traefik v3.7.17 (lego v5) registered an account with an empty email against a local test CA (Pebble). A10 is closed;
  no `/home-lab/traefik/acme-email` parameter is created.
- `aws_signing_helper` is **1.8.6** everywhere (plan text said 1.8.5). 1.8.6 rejects mismatched `Host` headers and exits at start if it cannot get
  credentials, so `ra-helper` restarts until AWS is reachable and the certificate is valid.
- **Access log (F03/F04): JSON on stdout, rotated by Docker.** `sudo docker logs traefik` carries both the access log and the application log, both JSON (access-log lines have a `DownstreamStatus` field);
  the json-file driver keeps 10 MB x 3, so nothing grows on the SD card and no logrotate is needed. The file `/apps/traefik/logs/access.log` of the first deploy
  was always empty and is no longer used. Root cause of the empty log: Traefik does not access-log requests handled by *internal* routers or services by
  default, and in M3 every request is internal (the dashboard `api@internal`, the HTTP-to-HTTPS redirect `web-to-websecure@internal`). Reproduced locally; fixed with
  `--accesslog.addInternals=true`, which also records the 401/403 of failed dashboard logins. (Application routers such as Authentik and Homepage log anyway.)
- **Tailscale NoSNAT (F02):** see the next section.
- Plan item Q14 is not defined in the rev 7 text (it points to rev 6); M3 is verified against the acceptance list in plan section 8 and S2/S17 below.

## Allowlist source address: Tailscale must not SNAT (F02)

Symptom: over Tailscale the dashboard answered 403 and Traefik saw the client as `172.30.0.1` (the `proxy` network gateway). Cause: Tailscale's
default `--snat-subnet-routes=true` masquerades traffic forwarded from `tailscale0` into a local network, and Docker's published ports are reached through the
bridge, so Traefik never saw the real `100.x` source and `lan-allowlist` rejected it. Fix: `--snat-subnet-routes=false`, in `TS_EXTRA_ARGS` of `tailscale/compose.yaml`
and already applied live with `tailscale set --snat-subnet-routes=false` (prefs `NoSNAT=true`).

Permanence: `TS_EXTRA_ARGS` is passed to `tailscale up`, which `TS_AUTH_ONCE=true` skips for an already logged-in node (I could not confirm from Tailscale's docs that
containerboot re-applies it on restart, so nothing here depends on that). The running node keeps the preference in its persisted state (`/apps/tailscale/state`); a
rebuilt node (new SD card, pi-recovery) takes it from the compose file. The live and compose values are identical, so a `tailscale up` with these args cannot conflict.
Check any time: `sudo docker exec tailscale tailscale --socket=/tmp/tailscaled.sock debug prefs | grep NoSNAT` (expect `true`).

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
sudo git -C /opt/home-lab status --short   # expect nothing (the checkout is root-owned: plain git says "dubious ownership")
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

`deploy.sh` pulls the repo, fetches secrets from SSM, pulls the images, builds `ra-helper` (needs Docker Hub for the two digest-pinned base images and `rolesanywhere.amazonaws.com` for the helper; no apt runs in the build (N8);
the build fails if the binary checksum is wrong) and starts everything. Wait about two minutes for the first DNS-01 issuance.

```bash
sudo docker compose -p home-lab -f compose.yaml --env-file config/lab.env --env-file /apps/secrets/runtime.env ps --format 'table {{.Name}}\t{{.Status}}'
```

Expected: `traefik` Up (healthy), `ra-helper` Up (healthy), `tailscale` Up.

### 2b. Applying the follow-up fixes to an already deployed M3 (F02-F05)

```bash
cd /opt/home-lab
sudo scripts/bootstrap.sh          # idempotent; installs /etc/sysctl.d/99-home-lab.conf (src_valid_mark=1) and applies it
sudo scripts/deploy.sh --no-git    # recreates traefik (access log on stdout, new healthcheck) and tailscale (NoSNAT in compose)
```

The tailnet drops for a few seconds while `tailscale` is recreated; the live NoSNAT preference is kept in its state. Then run 3.6 and 3.7.

## 3. Verify

```bash
DOMAIN="$(sudo sed -n 's/^DOMAIN=//p' /apps/secrets/runtime.env)"
```

### 3.1 ra-helper and credentials

```bash
sudo docker logs --tail 15 ra-helper                       # no "failed to generate initial credentials"
sudo docker logs traefik 2>&1 | grep -c 'no EC2 IMDS role' # 0
```

### 3.2 The staging wildcard was issued (acceptance 1)

```bash
sudo docker logs traefik 2>&1 | grep -iE 'acme|certificate|dns01' | tail -12
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
   (the plaintext is in the password manager). Correct: the Traefik dashboard loads, with the router `dashboard@file`.
3. From a device outside the LAN and tailnet (phone on mobile data, Tailscale off): the page must not load (the name resolves to a tailnet address that is
   unreachable). There are no port-forwards.

### 3.5 Hardening and isolation (S2, S17)

```bash
sudo ss -tlnp | grep -E ':(80|443|8080|2375|9911)\b'                        # docker-proxy on 0.0.0.0:80 and 0.0.0.0:443 only; NO [::]:80 or [::]:443 line (SEC-L2)
sudo docker inspect traefik --format '{{json .Mounts}}' | grep -c docker.sock   # 0
sudo docker ps -a --format '{{.Names}}' | grep -c socket-proxy                                   # 0 (SEC-H2: no proxy exists)
sudo docker inspect $(sudo docker ps -q) --format '{{.Name}}: {{range .Mounts}}{{.Source}} {{end}}' | grep -c docker.sock   # 0: no container mounts the socket
sudo docker inspect traefik --format '{{.Config.User}}'                                           # 10004:10004 (non-root)
sudo docker network ls --format '{{.Name}}' | grep -c '^socket-proxy$'                            # 0 (remove an old one: sudo docker network rm socket-proxy)
sudo docker inspect traefik ra-helper --format '{{.Name}}: {{range .Mounts}}{{.Source}} {{end}}' | grep -c 'host.key'   # 0
sudo docker inspect ra-helper --format '{{range .Mounts}}{{.Destination}} {{end}}'                      # /run/secrets/ra_acme_crt /run/secrets/ra_acme_key
sudo docker inspect traefik --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -ciE 'SECRET|TOKEN|ACCESS_KEY|PASSWORD'   # 0
sudo docker inspect traefik --format '{{range .Config.Cmd}}{{println .}}{{end}}' | grep -ciE 'insecure=true|api.debug|insecureSkipVerify|:8080'  # 0
```

On the Pi the `ss` line may also list Tailscale or other host listeners on unrelated ports; what matters is that nothing from Docker listens on 8080 or 2375
and that 9911 is not reachable from the host (it exists only inside Traefik's namespace).

### 3.6 The allowlist sees the real client address (F02) and the access log works (F03)

While a client (laptop over Tailscale, or a LAN device) loads `https://traefik.<your domain>/`, run this on the Pi in a second terminal and keep reloading the page:

```bash
PID="$(sudo docker inspect -f '{{.State.Pid}}' traefik)"
sudo nsenter -t "$PID" -n ss -tnH '( sport = :443 )'
```

Expected: the peer (right-hand) address is `100.x.y.z` for tailnet clients and `10.0.0.x` for LAN clients, **never `172.30.0.1`**. If `172.30.0.1` appears, NoSNAT is
not active: `sudo docker exec tailscale tailscale --socket=/tmp/tailscaled.sock set --snat-subnet-routes=false`.

```bash
sudo docker logs --tail 200 traefik 2>&1 | jq -r 'select(.DownstreamStatus) | [.ClientHost,.RouterName,.DownstreamStatus] | @tsv' | tail -5   # client, router, status
sudo rm -rf /apps/traefik/logs                                                                       # the unused, empty log directory of the first deploy
```

### 3.7 Tailscale F01 and F05

```bash
sudo docker logs tailscale 2>&1 | grep -ciE "modprobe|can't change directory"           # 0 for lines after this restart
sudo docker logs tailscale 2>&1 | grep -iE 'router:' | tail -3                          # shows nftables
sudo docker exec tailscale tailscale --socket=/tmp/tailscaled.sock status | head -3     # node still joined, same tailnet IP
sudo docker exec tailscale tailscale --socket=/tmp/tailscaled.sock debug prefs | grep NoSNAT   # true
sysctl net.ipv4.conf.all.src_valid_mark                                             # = 1 (set by bootstrap.sh)
sudo docker logs --since 2m tailscale 2>&1 | grep -c src_valid_mark                      # 0 after the restart; an old line is harmless once the sysctl is 1
```

If the old error text is still in `sudo docker logs` it is from before the recreate: judge only by lines after the container's new start time
(`sudo docker inspect tailscale --format '{{.State.StartedAt}}'`).

### 3.5b Published ports: IPv4 only, and an optional firewall rule (SEC-L2)

Docker publishes ports with its own iptables chains, which bypass host firewalls such as ufw. What the repo does: `traefik/compose.yaml` binds `0.0.0.0:80` and `0.0.0.0:443`
explicitly (a bare `80:80` would also make `docker-proxy` listen on `[::]`, which a global IPv6 address would expose), the allowlist denies every peer outside `10.0.0.0/24` and
`100.64.0.0/10`, and `scripts/preflight.sh --stage full` FAILs if a `[::]:80` or `[::]:443` listener exists. Check by hand: `sudo ss -tlnp | grep -E ':(80|443) '` (expect only `0.0.0.0`).

Optional extra layer, NOT applied by any script because it cannot be tested without the Pi and a wrong rule would cut the Pi off from the lab: drop new connections to 80 and 443 from
anywhere but the LAN and the tailnet in Docker's `DOCKER-USER` chain (the original destination port is matched with conntrack because the packet is already DNATed):

```bash
# LAN_CIDR and TAILNET_CIDR as in config/lab.env; run as root; ADD, test from the laptop and the tailnet, then persist (iptables-persistent) only if it works
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 443 ! -s 10.0.0.0/24 ! -s 100.64.0.0/10 -j DROP
sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 80  ! -s 10.0.0.0/24 ! -s 100.64.0.0/10 -j DROP
```

Remove a rule with the same command and `-D` instead of `-I`. Leave it out unless the router or the ISP ever hands the Pi a global IPv6 address.

## 4. Roll back

Stop the M3 stack only (secrets, networks and Tailscale stay):

```bash
cd /opt/home-lab
sudo docker compose -p home-lab -f compose.yaml --env-file config/lab.env --env-file /apps/secrets/runtime.env rm -sf traefik ra-helper
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
| DNS-01 timeout or `NXDOMAIN` | Route 53 propagation is slow; wait and restart Traefik (`sudo docker restart traefik`, the helper keeps running); resolvers are 1.1.1.1 and 8.8.8.8 and must be reachable from the Pi |
| Traefik exits at start | an unknown flag or a bad dynamic file: `sudo docker logs traefik`; `bash scripts/test-traefik-config.sh` reproduces it off the Pi |
| 403 over Tailscale, access log shows `172.30.0.1` | Tailscale is SNATing: see F02 (`tailscale set --snat-subnet-routes=false`); verify with the `nsenter ... ss` step in 3.6 |
| 403 from the laptop | the laptop is outside `10.0.0.0/24` and `100.64.0.0/10` (Wi-Fi guest network, VPN) |
| Port 80 or 443 already in use | another service on the Pi; `sudo ss -tlnp` |
| **421 Misdirected Request** on one host right after you added a service (seen on `dashboard.<domain>` after `auth.<domain>`) | The browser is reusing an old HTTP/2 connection that it opened to another host of the same wildcard certificate before the new router existed. Fresh connections are fine (`curl` with the right SNI and Host returns the normal 302/403). Close the browser completely, or flush its socket pools (`chrome://net-internals/#sockets`, "Flush socket pools"), and reload. There is now ONE TLS option set, so differing option names can no longer cause it; if it comes back after a TLS change, suspect a second option set. |
| Break-glass login still reachable after a reboot | It must not be: `home-lab-breakglass-reset.service` removes it at boot. Check `sudo scripts/breakglass.sh status` and `systemctl status home-lab-breakglass-reset`. |

## 6. Off-Pi checks (already run before this milestone was handed over)

`docker compose config` with dummy values for the root project; `scripts/test-traefik-config.sh` (runs the pinned Traefik image, as uid 10004, with the exact flags and the dynamic files:
healthcheck, no `:8080`, JSON access log on stdout, 308/301, TLS 1.1 and apex refused, allowlist 403 with headers, every lab host answers from the file provider,
no 421 across hosts, the break-glass drop-in switching a router on and off, no docker socket, key mount rules); the arm64 `ra-helper` image build with its
checksum; a Pebble (local test CA) run that proved the ACME account registers without an email and that lego's Route 53 provider takes credentials from
`127.0.0.1:9911` and the pinned zone ID. Only the real Roles Anywhere to Route 53 to staging CA path needs the Pi.
