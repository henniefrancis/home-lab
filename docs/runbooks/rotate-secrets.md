# Runbook: rotating secrets

One section per SecureString that `scripts/set-secret.sh` manages (the list is `config/secrets-manifest.tsv`; background in `secrets-ssm.md`):
`authentik/secret-key`, `authentik/postgres-password`, `authentik/bootstrap-password`, `traefik/breakglass-htpasswd`, `tailscale/auth-key`, `homepage/authentik-token`.

## The mechanics every rotation shares

1. **Generate** the new value in the password manager first (it keeps the offline copy). Never type a value into argv, shell history, a chat or an agent.
2. **Set it** on the laptop: `aws sso login --profile <profile>`, then `scripts/set-secret.sh <name>` (hidden prompt, asked twice, prints only the new version number). `scripts/set-secret.sh --check` lists versions, never values.
3. **Fetch it onto the Pi and recreate the consumer.** `sudo scripts/deploy.sh` fetches the new value into `/apps/secrets` (the file is replaced atomically) but does **not** restart anything: a running container keeps the file it was created with, and Compose leaves unchanged containers alone.
   So use the supported option that forces recreation of one stack: `sudo scripts/deploy.sh --recreate <stack>` (stacks: `authentik`, `traefik`, `tailscale`, `homepage`). It verifies the signed commit, fetches the secrets, then runs `docker compose up -d --force-recreate` for that stack only and never removes other stacks.
4. **Verify** as given per secret, then record the date in the password manager entry.
5. **Rollback** is always the same shape: set the previous value again from the password manager (`set-secret.sh <name>`), `sudo scripts/deploy.sh --recreate <stack>`, plus any in-app step noted below. SSM keeps older versions, but do not read them back: use the password manager copy.

If a deploy refuses on a signature, fix that first (`release-and-deploy.md`); rotation never needs `--offline`.

## authentik/postgres-password

Used by: `authentik-postgresql`, `authentik-server`, `authentik-worker` (stack `authentik`). Postgres only reads its password file when it first creates the data directory, so the **database must be changed in-app first**.

1. Generate a value under 99 characters, letters and digits only (no quotes, spaces or backslashes), store it in the password manager.
2. In-app (this is the `ALTER USER` step; `\password` runs it with a hidden prompt so the value never lands in argv or history), on the Pi: `sudo docker exec -it authentik-postgresql psql -U authentik -d authentik`, then `\password authentik`, type the new value twice, `\q`. Running Authentik connections keep working; new ones need the new value.
3. `scripts/set-secret.sh authentik/postgres-password` (the same value).
4. `sudo scripts/deploy.sh --recreate authentik` (recreates Postgres, server and worker; Postgres data lives in `/apps/authentik/postgres`, expect about a minute).
5. **Verify:** `sudo docker compose -p home-lab ps` shows the three containers healthy; `sudo docker logs authentik-server --since 5m | grep -i -E 'password|fatal|error'` shows nothing; log in at `https://auth.<domain>`.
6. **Rollback:** do steps 2 to 4 again with the old value (if step 2 was done and step 3 not, run `\password authentik` with the old value). Order matters: the database and SSM must always end up holding the same value.

## authentik/secret-key

Used by: `authentik-server`, `authentik-worker`. Signs cookies; per the Authentik configuration documentation (<https://docs.goauthentik.io/install-config/configuration/>), changing it invalidates active sessions. The page does not describe any other effect or a rotation procedure, so check the current Authentik release notes before a planned rotation, and take a `pg_dump` first (`sudo systemctl start home-lab-backup-authentik.service`). A restore from a backup does not need the old key (`authentik-backup.md` section 6); after a lost or stolen Pi, rotate it BEFORE the rebuild (`pi-recovery.md` section 1). Rotate it only after suspected exposure, not routinely.

1. Generate 60 or more random characters (letters and digits), store in the password manager.
2. `scripts/set-secret.sh authentik/secret-key`.
3. `sudo scripts/deploy.sh --recreate authentik`.
4. **Verify:** containers healthy; you are logged out; log in again with MFA at `https://auth.<domain>`; the dashboard (`https://dashboard.<domain>`) loads after the forward-auth login.
5. **Rollback:** set the previous value and recreate as above; sessions end again.

## authentik/bootstrap-password

Used by the worker's first start only (`akadmin` initial password). It should already be UNSET (`m4-authentik.md`, account hygiene). It is **not** a rotation target: to change the `akadmin` password use Authentik itself (User settings) or the recovery link in `m4-authentik.md` section 6. If it is set by mistake, write the placeholder back: `scripts/set-secret.sh --unset authentik/bootstrap-password`, then `sudo scripts/deploy.sh --recreate authentik`. Verify: `sudo test ! -s /apps/secrets/authentik/bootstrap-password && echo empty`. Rollback: not applicable (the value only matters on a database that has no admin yet).

## traefik/breakglass-htpasswd

Used by: Traefik (the `bg-traefik` Basic-auth login, off unless `scripts/breakglass.sh on`). Stack `traefik`.

1. Generate a new password in the password manager, then make the bcrypt line without putting the password in argv or history, exactly as in `m2-pi-setup.md` (`htpasswd -nBi -C 12 admin` through the `httpd:2.4-alpine` container).
2. `scripts/set-secret.sh traefik/breakglass-htpasswd` and paste the whole line.
3. `sudo scripts/deploy.sh --recreate traefik` (a short TLS gap while Traefik restarts; its `acme.json` certificate store is a volume and survives).
4. **Verify:** `sudo scripts/breakglass.sh on 5`, open `https://bg-traefik.<domain>/`: the new password works, the old one gives 401; then `sudo scripts/breakglass.sh off`.
5. **Rollback:** set the old line again and recreate Traefik.

## tailscale/auth-key

Used by: the `tailscale` container to join the tailnet once. It is normally UNSET; the node keeps its identity in its own state, so this is a **join key, not a credential that needs periodic rotation**. Replace it only to re-join (new SD card, lost node, `pi-recovery.md`).

1. Tailscale admin console: create a one-off key, tag `tag:homelab`, expiry one day. Store it in the password manager.
2. `scripts/set-secret.sh tailscale/auth-key`.
3. `sudo scripts/deploy.sh --recreate tailscale`.
4. **Verify:** `sudo docker exec tailscale tailscale status` shows the node online and tagged; the admin console lists it.
5. **Then set it back:** `scripts/set-secret.sh --unset tailscale/auth-key`, `sudo scripts/fetch-secrets.sh`, `sudo scripts/deploy.sh --recreate tailscale` (the env file is empty again). Revoke any unused key in the admin console.
6. **Rollback:** nothing to restore; an unused or rejected key only means the node does not join (`m2-pi-setup.md`, troubleshooting).

## homepage/authentik-token

Optional; used by the Homepage Authentik widget only if you enabled it (`m5-homepage.md`; the committed config does not use it, in which case the file is simply omitted).

1. In Authentik create a **new** read-only API token for the service account (Directory, Tokens), store it in the password manager.
2. `scripts/set-secret.sh homepage/authentik-token`.
3. `sudo scripts/deploy.sh --recreate homepage`.
4. **In-app, last:** delete the old token in Authentik (Directory, Tokens), after the check below.
5. **Verify:** the Authentik tile on `https://dashboard.<domain>` shows data, not an error; `sudo docker logs homepage --since 5m` has no 401.
6. **Rollback:** the old token still works until step 4; set it again and recreate Homepage. After step 4, create another token.

## After any rotation

`scripts/set-secret.sh --check` (all six present, on the home-lab key), `sudo scripts/preflight.sh --stage full` (no new FAIL), and note the date. If the old value may have been seen by someone else, also revoke it where it is honoured (Tailscale console, Authentik tokens), not just in SSM.
