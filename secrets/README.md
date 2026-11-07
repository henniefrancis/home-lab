# secrets/

This directory holds runtime secret files on the machine that runs the stack (the Raspberry Pi).
**Nothing in here is ever committed** except this README (and `.gitkeep`): `.gitignore` excludes
everything else in this directory.

Expected files appear in later milestones (for example the Authentik secret key and database
password, the break-glass htpasswd file, the Tailscale auth key, and the Roles Anywhere private key
and certificate). They reach containers through Compose secrets, `_FILE` variables, `file://` values
or `HOMEPAGE_FILE_*`, never as plain environment variables.

Rules:

- Permissions: directory `0700`; files `0400` (or `0600` where a service must rewrite them), owned by
  the user the consuming container runs as.
- Never print secret contents in logs, scripts, CI output or an agent's context.
- Generate secrets locally (for example `openssl rand -base64 48`); do not reuse values across services.
- The password manager is the source of truth; this directory is a runtime copy.
- Rotation steps are documented in `docs/runbooks/rotate-secrets.md` (added in a later milestone).
