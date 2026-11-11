# ADR-018: Root-start containers (the register)

Status: Accepted (owner decision, R19 planning). Builds on ADR-017 (Docker socket for Portainer and Netdata).

## Context
The lab rule is a numeric non-root `user:` (never 0, never 1000, the Pi's login user), a read-only root, `cap_drop: [ALL]` and
`no-new-privileges`. Some official images cannot run that way. Five services already start as root without a written register:
Tailscale, Pi-hole, Netdata, Portainer (ADR-017) and Home Assistant. Speedtest Tracker's only official image (LinuxServer.io, s6-overlay)
is a sixth: its init must start as root to set up `/run`, `/var` and `/config`, and then drops to `PUID`/`PGID`.

## Decision
- A register of exactly six services, each with the capabilities it may add back after `cap_drop: [ALL]`:
  `tailscale`, `pihole`, `netdata`, `portainer`, `homeassistant` and `speedtest-tracker`. The register is the file
  `config/adr-018-register.tsv`; no other service may start without a numeric non-root `user:`.
- Speedtest Tracker drops to PUID/PGID 10009 after init, keeps `cap_drop: [ALL]` plus only the capabilities the full container test proves
  necessary (each one removed in turn; the register holds only those whose removal breaks start-up), sets `no-new-privileges`, sits behind
  the LAN/tailnet allowlist and Authentik forward auth (admins only), has no Docker socket and no secret that matters.
- A service is added to the register only by amending this ADR first.
- `ra-helper` is not an exception: its Dockerfile sets `USER 10001:10001`, which the guard checks.

## Consequences
- A container escape from Speedtest Tracker's init phase is root on the Pi. The owner accepts this for a low-value, admin-only app. A
  future non-root image replaces the exception.
- CI step "Guard - non-root unless ADR-018 lists it" (`scripts/check-container-rules.sh`, self-test `scripts/test-container-rules.sh`)
  renders the root compose project and fails when a service lacks a numeric non-root `user:` (unless registered), lacks `cap_drop: [ALL]`,
  adds a capability the register does not list, lacks `no-new-privileges:true` (unless the register marks it exempt), is privileged, or when
  a register entry names a service that no longer exists.

Related: ADR-017, ADR-011.
