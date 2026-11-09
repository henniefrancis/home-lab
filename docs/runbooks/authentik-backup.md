# Runbook: Authentik backup and restore (K5, ADR-015)

Audience: the owner. Placeholders only (`<bucket>`, `<profile>`, `age1...`); the real values come from `terraform output`, the AWS SSO profile and the password manager.

The Authentik database holds the users, their password hashes, TOTP seeds and WebAuthn credentials, and the policy and flow state. It lives on the Pi's card. This runbook is the off-Pi
copy: encrypted on the Pi, stored in S3, restorable by you and nobody else.

```
systemd timer (nightly, about 02:30 plus up to 45 min, Persistent) -> home-lab-backup-authentik.service -> scripts/backup-authentik.sh
   docker exec authentik-postgresql pg_dump -Fc  |  age -r <your PUBLIC key>  |  aws s3 cp - s3://<bucket>/authentik/<UTC>.dump.age
   then a small marker object <UTC>.dump.age.ok, then /var/lib/home-lab/backup-authentik.last (an epoch)
failure -> exit 1, journal, one alert mail per day (key backup-authentik-failed), preflight WARN after 2 days, FAIL after 7
```

## How it is protected (ADR-015)

| Question | Answer |
|----------|--------|
| Who can read a dump? | Only someone with your **age identity** (private key, in the password manager only) **and** the owner AWS role. The Pi holds only the public recipient, so it can encrypt but never decrypt. |
| Can a stolen Pi destroy the backups? | No. Its role may `s3:PutObject` under `authentik/` and nothing else: no Get, List, Delete or ACL. The bucket is versioned and its policy denies deletes, reads and bucket changes to everybody except your admin role and the account root. A thief can only add objects (a few cents of junk). |
| Is a plaintext dump ever on disk? | No. `pg_dump` is piped straight into `age`, then into `aws s3 cp -`. The database password is read inside the container from its own secret file and never leaves it. |
| What does S3 do on top? | SSE-S3 (AES256), Block Public Access, no ACLs, TLS only. No KMS key: the payload is already encrypted, so a customer-managed key would add cost and a key policy to protect nothing more. |
| Retention | Noncurrent versions expire after 35 days, current dumps under `authentik/` after 400 days, failed multipart uploads after 1 day. About 400 nightly dumps of a few MB each: a few US cents a month. |

**Two objects per run.** `authentik/<UTC>.dump.age` is the encrypted dump; `authentik/<UTC>.dump.age.ok` (a few bytes: size and time) is written only after every stage succeeded and the dump
was not suspiciously small. The Pi cannot delete, so a failed or truncated upload stays in the bucket **without** a marker. Restore only from a dump that has its `.ok` sibling.

## 1. One-time owner setup [Laptop, then Pi], in this order

1. **Make the age key pair on the laptop.** Install age from its official releases (<https://github.com/FiloSottile/age>) or your package manager, then:

   ```bash
   age-keygen -o "$HOME/authentik-backup-identity.txt"      # prints: Public key: age1...
   ```

   - Copy the **whole file** (it starts with `# created:` and ends with the `AGE-SECRET-KEY-1...` line) into the password manager as a secure note called "home-lab Authentik backup age identity".
   - Note the `age1...` public key from the output (it is also on the `# public key:` line of the file).
   - **Delete the local file** (`rm "$HOME/authentik-backup-identity.txt"`) and clear the terminal scrollback. The identity must exist only in the password manager. Optionally keep an extra copy encrypted with a passphrase:
     `age -p -o identity.age <identity file>` before you delete it, stored on the CA USB stick (`ca-backup.md`). **Losing the identity makes every backup unreadable.**
2. **Terraform.** `terraform -chdir=terraform/bootstrap plan` with admin SSO. Expect exactly: **7 to add** (`aws_s3_bucket.backup`, its public access block, ownership controls, encryption configuration,
   versioning, lifecycle configuration and bucket policy), **2 to change in place** (`aws_iam_role_policy.pi_host` gains `WriteAuthentikBackups`; `aws_iam_role.pi_host` gets a new description), **0 to destroy**, and a new
   output `backup_bucket_name`. Anything that replaces or destroys a role is wrong: stop. Then apply.
3. **aws.env on the Pi.** On the laptop: `scripts/render-aws-env.sh --generation gen-1 --age-recipient age1...` prints the usual lines plus `BACKUP_S3_BUCKET=...` and `BACKUP_AGE_RECIPIENT=age1...`. On the Pi, append the two new lines (the
   last value of a key wins, so existing lines stay as they are):

   ```bash
   printf 'BACKUP_S3_BUCKET=<bucket>\nBACKUP_AGE_RECIPIENT=age1...\n' | sudo tee -a /etc/home-lab/aws.env > /dev/null
   sudo stat -c '%U:%G %a' /etc/home-lab/aws.env       # root:root 600
   ```

   Why `aws.env`: it is the root-only per-host file the alert path already reads, `render-aws-env.sh` already prints it, and the recipient is public, so it needs no secret store and no new IAM read right.
   The script validates both values (`age1` plus 58 characters; a bucket name) and refuses anything else, so a pasted private identity or a typo is never used silently.
4. **Release and bootstrap.** Release and deploy the commit as usual (`release-and-deploy.md`), then on the Pi: `sudo scripts/bootstrap.sh` (installs `age` from Debian's package, installs and enables
   `home-lab-backup-authentik.timer`), then `sudo scripts/preflight.sh --stage full`: `age`, `backup-recipient`, `backup-bucket` and `timer-home-lab-backup-authentik` should PASS; `backup-last` WARNs "never" until step 5.
5. **First backup.** `sudo systemctl start home-lab-backup-authentik.service` (it waits until done), then `journalctl -u home-lab-backup-authentik.service -n 20` (expect `OK, <n> bytes uploaded`).
   From the laptop with admin SSO: `aws s3 ls s3://<bucket>/authentik/ --profile <profile>` shows the `.dump.age` and its `.dump.age.ok`. `sudo scripts/preflight.sh --stage full` now shows `backup-last` PASS.
6. **Restore test** (section 3) the same day. Until it passes once, the backup is unproven.

## 2. Day to day

- `systemctl list-timers home-lab-backup-authentik.timer` (next and last run), `journalctl -u home-lab-backup-authentik.service`, `sudo cat /var/lib/home-lab/backup-authentik.last` (epoch of the last full success).
- Preflight: `backup-last` PASS under 2 days, WARN from 2 days, FAIL from 7 days. A failed night also mails once per day.
- Alert reasons and what to do:

| Reason in the alert or journal | What to do |
|--------------------------------|------------|
| `BACKUP_AGE_RECIPIENT is missing or not an age public key` | Owner setup step 3. |
| `the database container authentik-postgresql is not running` | `sudo docker compose ps`; `m4-authentik.md` section 6; the stack is down, which is a bigger problem than the backup. |
| `pg_dump failed` | The first line of its error is in the journal. Do not use the object that was written: it has no `.ok`. |
| `the S3 upload failed` with `AccessDenied` or a credential error | The Roles Anywhere certificate expired or the policy was not applied: `sudo scripts/cert-expiry.sh`, `terraform plan`. Test the identity: `sudo scripts/alert.sh test`. |
| `the backup is only N bytes` | An empty or truncated dump. The object has no `.ok`. Look at the Authentik database first. |
| `age is not installed` | `sudo scripts/bootstrap.sh`. |

- Rotating the age key: `age-keygen` again, update `BACKUP_AGE_RECIPIENT` on the Pi, keep the OLD identity in the password manager for as long as backups encrypted to it exist (400 days).

## 3. Restore test: into a throwaway PostgreSQL [Laptop; do it after setup, then at every drill]

This never touches the live database and never puts the identity on the Pi. Docker Desktop (or any Docker) on the laptop is enough.

1. **Pick and download a good dump** (owner SSO; the marker is the proof the upload finished):

   ```bash
   aws s3 ls s3://<bucket>/authentik/ --profile <profile>                      # newest *.dump.age that also has *.dump.age.ok
   aws s3 cp s3://<bucket>/authentik/<UTC>.dump.age.ok - --profile <profile>   # bytes=<n> ...
   aws s3 cp s3://<bucket>/authentik/<UTC>.dump.age ./authentik.dump.age --profile <profile>
   ```

   (Older versions: `aws s3api list-object-versions --bucket <bucket> --prefix authentik/ --profile <profile>`, then `aws s3api get-object --version-id ...`. Keys are timestamps, so a normal run never overwrites.)
2. **Decrypt** with the identity from the password manager. `-i -` reads the identity from standard input: paste it, then end input (Ctrl-D, or Ctrl-Z Enter on Windows). No identity file is created:

   ```bash
   age -d -i - -o authentik.dump authentik.dump.age
   ```

   `authentik.dump` is a PostgreSQL custom-format dump and contains password hashes and TOTP seeds: work on encrypted storage and delete it in step 6.
3. **Start a throwaway database with the same image as production.** Use the exact `image:` value of `authentik-postgresql` in `authentik/compose.yaml` (tag and digest) as `<postgres image>`:

   ```bash
   docker run -d --rm --name ak-restore-test -e POSTGRES_DB=authentik -e POSTGRES_USER=authentik -e POSTGRES_PASSWORD=throwaway-not-a-secret "<postgres image>"
   docker exec ak-restore-test pg_isready -U authentik -d authentik       # repeat until it accepts connections
   ```

4. **Restore into it** (the dump is read from standard input; `--exit-on-error` makes any problem loud):

   ```bash
   docker exec -i ak-restore-test pg_restore -U authentik -d authentik --clean --if-exists --no-owner --exit-on-error < authentik.dump
   ```

5. **Sanity queries** (row counts, not a full audit):

   ```bash
   docker exec ak-restore-test psql -U authentik -d authentik -Atc "select count(*) from authentik_core_user"
   docker exec ak-restore-test psql -U authentik -d authentik -Atc "select count(*) from authentik_core_application"
   docker exec ak-restore-test psql -U authentik -d authentik -c '\dt *device*'     # the MFA device tables exist
   ```

   Compare the user count with the live one: on the Pi, `sudo docker exec authentik-postgresql sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select count(*) from authentik_core_user"'`
   (a read-only query; a difference of a few rows is the time since the last backup). Zero users, or an error from `pg_restore`, is a failed restore test.
6. **Clean up:** `docker rm -f ak-restore-test`; delete `authentik.dump` and `authentik.dump.age`; clear the terminal scrollback if you pasted the identity there.
7. Record it in the drill log (`pi-recovery.md`): date, dump timestamp, user count, PASS or FAIL.

## 4. Real restore [Owner, laptop and Pi]

When: the database or the card is lost, or a bad change must be undone. Restore only into the same Authentik version as the dump or a newer one (Authentik migrates forward at start, never back).
The Authentik **secret key** in SSM (`authentik/secret-key`) must be the one that was in use when the dump was taken: it encrypts fields inside the database. Do not rotate it between backup and restore.

1. On the laptop: download and decrypt as in section 3, steps 1 and 2. Check it first: `pg_restore --list authentik.dump | head` must print a table of contents.
2. Copy `authentik.dump` to the Pi through Raspberry Pi Connect file transfer, or `scp` over Tailscale. It contains password hashes and TOTP seeds: put it in a root-only directory (`sudo install -d -m 0700 /root/restore`) and delete it in step 6.
3. Pi, stack running (after a rebuilt Pi: `pi-recovery.md` sections 2 to 5 first, so that `deploy.sh` has started the empty database). Stop the application containers; PostgreSQL stays up:

   ```bash
   dc() { sudo docker compose -p home-lab -f /opt/home-lab/compose.yaml --env-file /opt/home-lab/config/lab.env --env-file /apps/secrets/runtime.env "$@"; }
   dc stop authentik-server authentik-worker
   ```

4. Restore over the current content (the password is read inside the container; the dump goes in on standard input):

   ```bash
   sudo docker exec -i authentik-postgresql sh -c 'PGPASSWORD="$(cat /run/secrets/pg_password)" exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --exit-on-error' < /root/restore/authentik.dump
   ```

5. Start again and wait for healthy: `dc start authentik-server authentik-worker`, then `dc ps` (both healthy; Authentik runs its migrations at start, so allow a few minutes).
6. Delete the dump: `sudo rm -rf /root/restore`. On the laptop delete `authentik.dump` and `authentik.dump.age`.
7. **Verify:** `https://auth.<domain>` shows the login; log in with your named admin **and the existing MFA device** (the TOTP seeds and WebAuthn credentials come back with the dump); open a protected app (the dashboard) through forward auth;
   `sudo scripts/preflight.sh --stage full`. If the restored data is not what you wanted, restore an older object the same way.
8. Record it in the drill log.

If no usable backup exists, the fallback is the blueprint path in `pi-recovery.md` section 6: groups, providers, applications and the MFA policy come back, but users and MFA devices must be re-created.

## Related

`pi-recovery.md` (section 6), `m4-authentik.md` (section 6), `alerting.md`, `ca-backup.md`, `secrets-ssm.md`. Design record: ADR-015 in the Obsidian vault (Decisions).
