# ADR-018: Root-start containers (the register)

Status: Accepted. Date: 2026-11-11 (owner decision during R19 planning).

## Context
The lab rule is a numeric non-root `user:` (never 0, never 1000, the Pi's login user), a read-only root, `cap_drop: [ALL]` and
`no-new-privileges`. Some official images cannot run that way. Five services already started as root without a written register: Tailscale, Pi-hole,
Netdata, Portainer and Home Assistant. Portainer and Netdata mount the Docker socket, which is root-equivalent: that risk was accepted separately by the
owner (both are reachable only from the LAN and tailnet, behind Authentik forward auth with MFA for admins). Speedtest Tracker's only official image
(LinuxServer.io, s6-overlay) is a sixth: its init starts as root, prepares `/run`, `/var` and `/config`, and then drops to `PUID`/`PGID`.

## Decision
A register of exactly six services. Each adds back only the capabilities listed after `cap_drop: [ALL]`. The register is the file
`config/adr-018-register.tsv`, and the CI guard reads it.

| Service | Capabilities added back | no-new-privileges |
| --- | --- | --- |
| `tailscale` | NET_ADMIN | required |
| `pihole` | CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, SETFCAP, NET_BIND_SERVICE | exempt |
| `netdata` | SYS_PTRACE, SYS_ADMIN, SETUID, SETGID, CHOWN, DAC_OVERRIDE, DAC_READ_SEARCH, FOWNER | exempt |
| `portainer` | none | required |
| `homeassistant` | NET_ADMIN, NET_RAW | exempt |
| `speedtest-tracker` | CHOWN, DAC_OVERRIDE, SETUID, SETGID | required |

- "Exempt" (pihole, netdata, homeassistant) means the image's entrypoint or host-network agent needs setuid and file capabilities, so
  `no-new-privileges` may be absent. Every other service must set it.
- Speedtest Tracker drops to PUID/PGID 10009 after init, keeps `cap_drop: [ALL]` plus the four capabilities its container test proves necessary (each one is
  removed in turn; the register holds exactly those whose removal stops start-up), sets `no-new-privileges`, sits behind the LAN/tailnet allowlist and Authentik forward
  auth (admins only), has no Docker socket and holds nothing of value.
- Adding a service to the register, or changing an entry (a capability, or the `no-new-privileges` flag), requires an amendment of this ADR first.
- `ra-helper` is not an exception: its Dockerfile sets `USER 10001:10001`, which the guard checks.

## Consequences
- A container escape from Speedtest Tracker's init phase is root on the Pi. The owner accepts this for a low-value, admin-only app. A future non-root image replaces the exception.
- CI step "Guard - non-root unless ADR-018 lists it" (`scripts/check-container-rules.sh`, self-test `scripts/test-container-rules.sh`) renders the root compose project and
  fails when a service lacks a numeric non-root `user:` (unless registered), lacks `cap_drop: [ALL]`, adds a capability the register does not list, lacks
  `no-new-privileges:true` (unless the register marks it exempt), is privileged, or when a register entry names a service that no longer exists.
