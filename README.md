# home-lab

A hardened, reproducible edge layer for a Raspberry Pi 4B home lab, built in the open.

Every service is reachable by name over HTTPS with a real Let's Encrypt certificate, never by typing a
port, and only from the home LAN or over Tailscale. Everything is behind single sign-on with MFA.
All AWS infrastructure is Terraform.

> Status: **milestone M0** (repository skeleton and hygiene). Service and infrastructure code arrives
> milestone by milestone, each reviewed before the next starts. The single source of truth is
> [`docs/plan/phase-1-traefik.md`](docs/plan/phase-1-traefik.md).

## What it will run

| Layer | Component |
|-------|-----------|
| Reverse proxy | Traefik v3 on ports 80/443 only, talking to Docker through a read-only socket proxy |
| TLS | Let's Encrypt wildcard certificate for `*.${DOMAIN}` via DNS-01 on Route 53 |
| Identity | Authentik SSO with MFA and per-app forward auth (host-only cookies) |
| Networking | Tailscale for remote access, no router port-forwards |
| Dashboard | Homepage at `https://dashboard.${DOMAIN}` |
| DNS and AWS | Route 53 zone managed by Terraform, IAM Roles Anywhere for the Pi (no long-lived keys), budget alert |
| Terraform | HCP Terraform: remote execution, OIDC dynamic credentials with split plan/apply roles, no AWS keys stored |

Routing is by subdomain. The apex `${DOMAIN}` and `www` are reserved for a separate future public site and
are never served from the Pi.

**Rule: no console or CLI changes to Route 53.** Every DNS change goes through Terraform.

## Milestones (Phase 1)

| Milestone | Scope |
|-----------|-------|
| M0 | Repo reset: hygiene files, README, CI, gitleaks, Dependabot, placeholders |
| M1 | HCP Terraform and AWS foundation; adopt the existing Route 53 zone, records and registered-domain nameservers into Terraform |
| M2 | Pi preflight, bootstrap, Tailscale, private CA for Roles Anywhere, wildcard DNS record |
| M3 | Traefik, socket proxy and Roles Anywhere helper (Let's Encrypt staging) |
| M4 | Authentik SSO |
| M5 | Homepage on `dashboard.${DOMAIN}` |
| M6 | Production certificate, hardening, repo made public |

Later phases (not scheduled): Route 53 DNSSEC signing, more services (`ha.`, `tools.`, `links.`,
`netdata.`, `pihole.`, `portainer.`), and managing HCP objects with the `tfe` provider.

## Configuration and secrets

- All real values (domain, email, zone ID, AWS account, HCP organization, role ARNs) live in gitignored
  files or HCP workspace variables: copy `.env.example` to `.env` and edit it. `*.tfvars` and
  `*.auto.tfvars` files are never committed.
- Runtime secret files go in `secrets/` (also gitignored; see [`secrets/README.md`](secrets/README.md)).
  The password manager is the source of truth.
- Placeholders in this repo are `example.com` and `you@example.com`.

## Prerequisites (filled in during M1-M2)

- AWS account with IAM Identity Center, and an HCP Terraform organization (free tier is sufficient).
- Raspberry Pi 4B, 64-bit Raspberry Pi OS, Docker with Compose 2.20 or newer.
- A domain registered with Route 53 Domains (or otherwise delegated to a Route 53 hosted zone).

## Development

```sh
pip install pre-commit yamllint
pre-commit install          # gitleaks, yaml, shellcheck hooks on every commit
yamllint --strict .
```

CI is a single lean job on pushes to `main` and on pull requests (docs-only changes are skipped). It
runs gitleaks over the full history, yamllint, shellcheck, `docker compose config` and the repo guards
(no tracked `*.tfvars`, no `aws_route53domains_domain`). It has no cloud or HCP credentials. While the
repo is private the GitHub Actions budget is capped at 100 minutes a month, so keep CI lean.

## Security

See [`SECURITY.md`](SECURITY.md). Report vulnerabilities privately.

## Licence

[MIT](LICENSE) (c) 2026 Hennie Francis
