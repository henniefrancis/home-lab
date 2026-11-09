# Runbook: Authentik backup and restore (K5, ADR-015)

Audience: the owner. Placeholders only (`<bucket>`, `<profile>`, `age1...`); the real values come from `terraform output`, the AWS SSO profile and the password manager.

The Authentik database holds the users, their password hashes, TOTP seeds and WebAuthn credentials, and the policy and flow state. It lives on the Pi's card. This runbook is the off-Pi
copy: encrypted on the Pi, stored in S3, restorable by you and nobody else.

```
systemd timer (nightly, about 02:30 plus up to 45 min, Persistent) -> home-lab-backup-authentik.service -> scripts/backup-authentik.sh
   docker exec authentik-postgresql pg_dump -Fc  |  age -r <your PUBLIC key>  |  aws s3 cp - s3://<bucket>/authentik/<UTC>.dump.age
   then a small marker object <UTC>.dump.age.ok, then /var/lib/home-lab/backup-authentik.last (an epoch)
failure -> exit 1, journal, one alert mail per day (key backup-authentik-failed), preflight WARN after 2 days, FAIL after 7
/etc/home-lab/restore-pending exists -> the run is skipped (exit 0, logged, no mail): see section 5
```

## How it is protected, and what it does not protect (ADR-015)

| Question | Answer |
|----------|--------|
| Who can read a dump? | Only someone with your **age identity** (private key, in the password manager only) **and** the owner AWS role. The Pi holds only the public recipient, so it can encrypt but never decrypt. |
| Can a stolen Pi read or delete backups? | No. Its role may `s3:PutObject` under `authentik/` and nothing else: no Get, List, Delete or ACL. The bucket policy denies deletes, reads, SSE-C uploads and bucket changes to everybody except your admin role and the account root. |
| **Can a stolen Pi add or replace backups?** | **Yes, and you must not trust a dump by its name.** age encrypts to a public key, so a thief can upload a validly encrypted, hostile dump with a future timestamp and a forged `.ok`, or upload over an existing key (a new version; the good one becomes a noncurrent version that is kept 90 days). The `.ok` marker is an **accident control only** (it tells you the nightly run finished); it is not proof of origin. Section 4 is the rule for choosing a dump. |
| Why no `If-None-Match`? | S3 can refuse overwrites with the `s3:if-none-match` condition key ([conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html), [enforcing them](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes-enforce.html)), but the AWS documentation lists the header only for `s3api put-object`, `complete-multipart-upload` and `copy-object`; the high-level `aws s3 cp -` stream the script uses has no documented option for it. It was not enforced. The compensating controls are versioning, 90 days of noncurrent versions, and the one-version-per-key check in section 4 and the drill. A later hardening is to spool the encrypted dump to a private file and use `s3api put-object --if-none-match "*"`. |
| Is a plaintext dump ever on the Pi's disk? | Not by the backup. `pg_dump` is piped straight into `age`, then into `aws s3 cp -`. The database password is read inside the container from its own secret file and never leaves it. A restore (section 6) streams too: no plaintext file on the Pi, and the owner identity never goes to the Pi. |
| What does S3 do on top? | SSE-S3 (AES256), Block Public Access, no ACLs, TLS only. No KMS key: the payload is already encrypted. |
| Retention and cost | Noncurrent versions 90 days, current dumps under `authentik/` 400 days, `restore/` copies 1 day, failed multipart uploads 1 day. About 400 nightly dumps of a few MB: a few US cents a month. A USD 1 monthly cost budget on S3 mails the alert address if a thief floods the bucket (CloudWatch alarms cannot publish to the `alias/aws/sns` alert topic: [AWS re:Post](https://repost.aws/knowledge-center/cloudwatch-configure-alarm-sns)). |

**Two objects per run.** `authentik/<UTC>.dump.age` is the encrypted dump; `authentik/<UTC>.dump.age.ok` (a few bytes: size and time) is written only after every stage succeeded and the dump
was not suspiciously small. The Pi cannot delete, so a failed or truncated upload stays in the bucket without a marker.

## 1. One-time owner setup [Laptop, then Pi], in this order

0. **Laptop prerequisites:** the list is in `pi-recovery.md` section 0.5 (recovery kit): AWS SSO profile with the admin role, `terraform login` and `TF_CLOUD_ORGANIZATION`, aws CLI v2, age, Docker, git and the signing key, the password manager.
1. **Make the age key pair on the laptop**, in a directory that is **not** cloud-synced (not a OneDrive or Dropbox folder). Install age from its official releases (<https://github.com/FiloSottile/age>) or your package manager, then:

   ```bash
   cd "$(mktemp -d)"                                   # a scratch directory outside any synced folder
   age-keygen -o identity.txt                          # prints: Public key: age1...
   age -p -o identity.age identity.txt                 # a passphrase-encrypted second copy (required, see below)
   ```

   - Copy the **whole `identity.txt`** (`# created:`, `# public key:` and the `AGE-SECRET-KEY-1...` line) into the password manager as a secure note "home-lab Authentik backup age identity". The passphrase of `identity.age` goes in a different item.
   - **Put `identity.age` on the CA USB stick** (`ca-backup.md`). It is required, not optional: the password manager copy is a single point of failure, and **losing the identity makes every backup unreadable**.
   - Note the `age1...` public key. Then delete the scratch directory (`rm -rf` it) and clear the terminal scrollback.
2. **Terraform.** `terraform -chdir=terraform/bootstrap plan` with admin SSO. Expect exactly: **8 to add** (`aws_s3_bucket.backup`, its public access block, ownership controls, encryption configuration,
   versioning, lifecycle configuration and bucket policy, plus the `aws_budgets_budget.backup_storage` budget), **2 to change in place** (`aws_iam_role_policy.pi_host` gains `WriteAuthentikBackups`; `aws_iam_role.pi_host` gets a new description),
   **0 to destroy**, and a new output `backup_bucket_name`. Anything that replaces or destroys a role is wrong: stop. The bucket policy is applied last on purpose (its denies would lock a half-finished apply out if your admin role did not match `owner_role_arn_pattern`; the pattern in use was checked against the live role on 2026-11-09). Then apply.
3. **aws.env on the Pi.** On the laptop: `scripts/render-aws-env.sh --generation gen-1 --age-recipient age1...` prints the usual lines plus `BACKUP_S3_BUCKET=...` and `BACKUP_AGE_RECIPIENT=age1...` (and refuses a recipient with a bad checksum when age is installed). On the Pi, append the two new lines (the
   last value of a key wins, so existing lines stay as they are):

   ```bash
   printf 'BACKUP_S3_BUCKET=<bucket>\nBACKUP_AGE_RECIPIENT=age1...\n' | sudo tee -a /etc/home-lab/aws.env > /dev/null
   sudo stat -c '%U:%G %a' /etc/home-lab/aws.env       # root:root 600
   ```

   Why `aws.env`: it is the root-only per-host file the alert path already reads, `render-aws-env.sh` already prints it, and the recipient is public, so it needs no secret store and no new IAM read right.
4. **Release and bootstrap.** Release and deploy the commit as usual (`release-and-deploy.md`), then on the Pi: `sudo scripts/bootstrap.sh` (installs `age` from Debian's package, installs and enables
   `home-lab-backup-authentik.timer`), then `sudo scripts/preflight.sh --stage full`: `age`, `backup-recipient`, `backup-bucket` and `timer-home-lab-backup-authentik` should PASS; `backup-last` WARNs "never" until step 5.
5. **First backup.** `sudo systemctl start home-lab-backup-authentik.service` (it waits until done), then `journalctl -u home-lab-backup-authentik.service -n 20` (expect `OK, <n> bytes uploaded`).
   From the laptop with admin SSO: `aws s3 ls s3://<bucket>/authentik/ --profile <profile>` shows the `.dump.age` and its `.dump.age.ok`. `sudo scripts/preflight.sh --stage full` now shows `backup-last` PASS.
6. **Check the hardened unit on the Pi (first real run).** The unit's hardening (capability set, `ProtectProc`, `ProcSubset`, memory limit) was verified offline only. After the first successful run of step 5, run `systemd-analyze security home-lab-backup-authentik.service` and note the overall exposure score (the offline baseline was about 4, OK). If step 5 failed with a permission error that the plain script does not have, **fall back**: remove the most recent hardening option you suspect (the `CapabilityBoundingSet` line first, then `ProtectProc` and `ProcSubset`), `sudo systemctl daemon-reload`, start the unit again, and tell the developer.
7. **Restore test** (section 5) the same day. Until it passes once, the backup is unproven.

## 2. Day to day

- `systemctl list-timers home-lab-backup-authentik.timer` (next and last run), `journalctl -u home-lab-backup-authentik.service`, `sudo cat /var/lib/home-lab/backup-authentik.last` (epoch of the last full success).
- **The daily alert path watches the backup too** (SEC L-6). `alert.sh check`, run by the daily certificate timer, also runs `scripts/backup-age-check.sh` when `BACKUP_S3_BUCKET` is set: WARN when the last success (`backup-authentik.last`) is more than 2 days old, CRITICAL after 7; mails "Authentik backup age" through the same rate-limited alert library, one mail per state a day, an escalation mails again. If no success was ever recorded, the clock starts when the check first saw backups configured (`/var/lib/home-lab/backup-authentik.first-seen`, written once). A `restore-pending` file older than 3 days WARNs (7 days CRITICAL) with a message that says the sentinel is stopping the backups, so a forgotten sentinel can no longer be silent.
- Preflight: `backup-last` PASS under 2 days, WARN from 2 days, FAIL from 7 days; `backup-restore-pending` WARNs while the sentinel exists. A failed night also mails once per day.
- Alert reasons and what to do:

| Reason in the alert or journal | What to do |
|--------------------------------|------------|
| `BACKUP_AGE_RECIPIENT is missing or not an age public key` | Owner setup step 3. |
| `the database container authentik-postgresql is not running` | `sudo docker compose ps`; `m4-authentik.md` section 6; the stack is down, which is a bigger problem than the backup. |
| `pg_dump failed` | The first line of its error is in the journal. Do not use the object that was written: it has no `.ok`. |
| `the S3 upload failed` with `AccessDenied` or a credential error | The Roles Anywhere certificate expired or the policy was not applied: `sudo scripts/cert-expiry.sh`, `terraform plan`. Test the identity: `sudo scripts/alert.sh test`. |
| `the backup is only N bytes` | An empty or truncated dump. The object has no `.ok`. Look at the Authentik database first. |
| `age is not installed` | `sudo scripts/bootstrap.sh`. |

- **Hardening notes.** The unit is root with a capability bounding set of `CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH`, a private `/proc` (`ProtectProc=invisible`, `ProcSubset=pid`), `UMask=0077` and memory, task and CPU limits. These were checked with `systemd-analyze verify` only. If the first run on the Pi fails with a permission error that the plain script did not have, remove the most recent option you suspect (the capability set first), run `sudo systemctl daemon-reload` and start the unit again, and tell the developer.
- **Rotating the age key:** `age-keygen` again, update `BACKUP_AGE_RECIPIENT` on the Pi, keep the OLD identity in the password manager for as long as backups encrypted to it exist (400 days).
- **Size and count check (monthly, and in the drill):**
  `aws s3api list-objects-v2 --bucket <bucket> --prefix authentik/ --profile <profile> --query '[length(Contents), sum(Contents[].Size)]'`: roughly one dump and one marker a day, each a few MB at most. A sudden jump means someone is writing.

## 3. Reading the bucket: every version, never by name

Everything that picks a dump uses S3's own metadata (`LastModified`, `VersionId`, `Size`), because a thief with the Pi's certificate controls key names and markers but not S3's clock.

```bash
aws s3api list-object-versions --bucket <bucket> --prefix authentik/ --profile <profile> --output text \
  --query 'Versions[?ends_with(Key, `.dump.age`)].[LastModified,Key,VersionId,Size,IsLatest]' | sort > versions.txt
cat versions.txt                                                       # oldest first
awk '{c[$2]++} END {for (k in c) if (c[k] > 1) print "MORE THAN ONE VERSION (an overwrite): " k}' versions.txt
```

## 4. Choosing a dump safely (rules)

1. **Reject any key that has more than one version** (the awk line above prints it). A normal run never overwrites; a second version means someone wrote over it. Look at all its versions and the neighbours before trusting any of them.
2. **Pick by `LastModified`, not by the name.** The key's timestamp must agree with `LastModified` within about an hour (the timer's 45 minute delay plus the upload time). A key dated in the future, or far from its `LastModified`, is hostile or broken.
3. **After a theft or any suspicion, pick a dump from before the incident time.** Treat every object newer than the last night you are sure about as tainted. Disable the trust anchor or bump `pki_generation` first (`pi-recovery.md` section 1) so nothing new arrives while you decide.
4. **Compare sizes** (`Size` in `versions.txt`) with the neighbours; one far smaller or larger than its neighbours is suspect. The marker is not evidence: it is an accident control only.
5. **Always restore into a throwaway container first** (section 5), with no network, and look at what is inside before you touch the live database: user count, the usernames you expect, that no unknown account exists.
6. Download by version: `aws s3api get-object --bucket <bucket> --key <key> --version-id <VersionId> --profile <profile> authentik.dump.age`.

A custom-format dump carries SQL that `pg_restore` runs as the database superuser. That is why steps 1 to 5 exist: restore only what you have chosen by these rules, first into a container that cannot reach anything.

## 5. Restore test: into a throwaway PostgreSQL [Laptop; after setup, then at every drill]

This never touches the live database, never puts the identity on the Pi and leaves no plaintext file. Docker on the laptop is enough.

1. Choose and download a dump by sections 3 and 4.
2. **Start a throwaway database with the same image as production and NO network.** Use the exact `image:` value of `authentik-postgresql` in `authentik/compose.yaml` (tag and digest) as `<postgres image>`:

   ```bash
   docker run -d --rm --name ak-restore-test --network none -e POSTGRES_DB=authentik -e POSTGRES_USER=authentik -e POSTGRES_PASSWORD=throwaway-not-a-secret "<postgres image>"
   docker exec ak-restore-test pg_isready -U authentik -d authentik       # repeat until it accepts connections
   ```

3. **Decrypt and restore in one pipe** (age reads the identity from standard input, which is why the ciphertext is a file argument: paste the identity from the password manager, then end input with Ctrl-D, or Ctrl-Z Enter on Windows). `--exit-on-error` makes any problem loud:

   ```bash
   age -d -i - authentik.dump.age | docker exec -i ak-restore-test pg_restore -U authentik -d authentik --clean --if-exists --no-owner --exit-on-error
   ```

4. **Look inside** (read-only queries on the throwaway):

   ```bash
   docker exec ak-restore-test psql -U authentik -d authentik -Atc "select count(*) from authentik_core_user"
   docker exec ak-restore-test psql -U authentik -d authentik -c "select username, is_active, last_login, date_joined from authentik_core_user order by date_joined"
   docker exec ak-restore-test psql -U authentik -d authentik -Atc "select count(*) from authentik_core_application"
   docker exec ak-restore-test psql -U authentik -d authentik -Atc "select relname from pg_class where relkind = 'r' and relname like 'authentik_stages_authenticator%' order by 1"
   ```

   Expect your usernames and nobody else, a user count close to the live one (on the Pi: `sudo docker exec authentik-postgresql sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select count(*) from authentik_core_user"'`, read-only), applications present, and the authenticator tables present.
   **An unknown account, zero users or a `pg_restore` error is a failed test: do not restore that dump to the live database.**
5. **Clean up:** `docker rm -f ak-restore-test`; delete `authentik.dump.age`, `versions.txt` and the scratch directory; clear the scrollback if you pasted the identity there.
6. Record it in the drill log (`pi-recovery.md`): date, dump `LastModified` and `VersionId`, user counts, PASS or FAIL, and how long it took.

## 6. Real restore [Owner, laptop and Pi]

When: the database or the card is lost, or a bad change must be undone. Restore only into the same Authentik version as the dump or a newer one (Authentik migrates forward at start, never back).

**What the dump does and does not carry.** `pg_dump -Fc` of one database does not include roles (global objects), so the new database keeps the PostgreSQL password it was created with. After a rebuild that password is whatever SSM `authentik/postgres-password` holds when `deploy.sh` first starts the container: in the stolen-Pi case rotate it in SSM **before** the rebuild (`pi-recovery.md` section 1), and the new container simply initialises with it; no `ALTER USER` is needed and the restore brings back data only.
**The Authentik secret key.** The official configuration reference describes `AUTHENTIK_SECRET_KEY` only as the cookie-signing key, and says changing it invalidates active sessions ([configuration](https://docs.goauthentik.io/install-config/configuration/)); it does not say the database content depends on it. So the restore does not need the old key, and after a lost or stolen Pi you rotate it (the old one was on the card). After the restore, verify login, MFA, a protected application and the outpost (step 8). If a provider or token misbehaves afterwards, re-enter it in the admin interface rather than going back to the exposed key.

The dump has to get from your laptop to the Pi without a plaintext file on the Pi and without the owner identity going there. The Pi cannot read S3 (write-only by design), Raspberry Pi Connect has no file transfer and the tailnet policy allows only ports 80 and 443. So the laptop re-encrypts the dump to a **one-off key that exists only in the Pi's memory-backed `/run`**, puts it under `restore/` for a few minutes, and the Pi pulls it with a presigned URL.

1. **Pi (Raspberry Pi Connect shell).** Start a root shell and make a one-off key in `/run` (tmpfs, never on the card):

   ```bash
   sudo -i
   install -d -m 0700 /run/ak-restore
   age-keygen -o /run/ak-restore/id.txt              # prints: Public key: age1...   (copy ONLY this line's key)
   ```

2. **Laptop.** Download the chosen version (section 4), then re-encrypt it to the Pi's one-off key and upload it under `restore/` as the owner (the bucket policy allows the owner to write there; the Pi role cannot). The plaintext exists only in the pipe:

   ```bash
   aws s3api get-object --bucket <bucket> --key <key> --version-id <VersionId> --profile <profile> authentik.dump.age
   age -d -i - authentik.dump.age | age -r <one-off age1 key from the Pi> | aws s3 cp - s3://<bucket>/restore/authentik-restore.dump.age --profile <profile>
   aws s3 presign s3://<bucket>/restore/authentik-restore.dump.age --expires-in 900 --region af-south-1 --profile <profile>
   ```

   `aws s3 presign` prints a URL that works for 900 seconds (the default is 3600; the maximum 7 days; a URL made with temporary SSO credentials also stops when those expire: [presign](https://docs.aws.amazon.com/cli/latest/reference/s3/presign.html), [presigned URLs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html)). It acts with **your** permissions, so the bucket policy's owner exemption applies. The object inside is encrypted to the one-off key: even the URL alone yields nothing readable.
3. **Pi.** Stop the application containers (PostgreSQL stays up), paste the URL at the hidden prompt, and stream it in. The dump goes `curl -> age -> pg_restore` through pipes only:

   ```bash
   dc() { docker compose -p home-lab -f /opt/home-lab/compose.yaml --env-file /opt/home-lab/config/lab.env --env-file /apps/secrets/runtime.env "$@"; }
   dc stop authentik-server authentik-worker
   read -r -s URL            # paste the URL, press Enter (nothing is echoed or kept in history)
   set -o pipefail
   curl -fsS "$URL" | age -d -i /run/ak-restore/id.txt | docker exec -i authentik-postgresql sh -c 'PGPASSWORD="$(cat /run/secrets/pg_password)" exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --exit-on-error'
   echo "restore pipeline exit code: $?"      # must be 0
   ```

   **If the code is not 0 (an expired URL, a truncated download, a restore error), the live database may now be EMPTY or half restored:** `--clean` drops the tables before it loads them, so a failed or truncated run leaves a gutted database. **Keep `authentik-server` and `authentik-worker` stopped until `pg_restore` exits 0.** A repeat is safe (`--clean --if-exists`): create a new URL (step 2, last command) and run the last block again, as often as it takes. Do not start the server on a database you have not restored successfully.
   A very long presigned URL (a large SSO session token) can be cut by the terminal's line limit when pasted, and a cut URL gives `403`: on the laptop check its length (`... | wc -c`, keep it under about 4000 characters) before you paste it.
4. **Pi, clean up.** `shred -u /run/ak-restore/id.txt; rmdir /run/ak-restore; unset URL`. **Laptop:** remove the `restore/` object and its version: `aws s3api list-object-versions --bucket <bucket> --prefix restore/ --profile <profile>`, then `aws s3api delete-object --bucket <bucket> --key restore/authentik-restore.dump.age --version-id <VersionId> --profile <profile>` for each (the lifecycle removes it after one day anyway); delete `authentik.dump.age` and clear the scrollback.
5. **Pi:** `dc start authentik-server authentik-worker`, then `dc ps` (both healthy; Authentik runs its migrations at start, so allow a few minutes).
6. **Remove the sentinel** `/etc/home-lab/restore-pending` (`rm /etc/home-lab/restore-pending`), so the nightly backup resumes (section 7), and `exit` the root shell.
7. **After a theft: reset every user** (`pi-recovery.md` section 1.6). The restored password hashes and TOTP seeds were on the stolen card.
8. **Verify:** `https://auth.<domain>` shows the login; log in with your named admin **and the existing MFA device** (or the new one after the post-theft reset); open a protected app (the dashboard) through forward auth; `sudo scripts/preflight.sh --stage full`. Record the restore and its duration in the drill log.

If no usable backup exists, the fallback is the blueprint path in `pi-recovery.md` section 6: groups, providers, applications and the MFA policy come back, but users and MFA devices must be re-created.

## 7. The empty-database trap on a rebuilt Pi

`bootstrap.sh` enables the backup timer, and `deploy.sh` starts a fresh, empty Authentik whose dump is a valid 300 KB file. If the timer ran before your restore, the newest object would be the empty database, with a `.ok`. So the recovery runbook has you create `/etc/home-lab/restore-pending` **before** `bootstrap.sh`: while it exists `backup-authentik.sh` logs "restore in progress", exits 0 and uploads nothing (no alert, because nothing is wrong), and `preflight.sh` shows a `backup-restore-pending` WARN. You remove it in section 6 step 6. If you forget, `backup-last` WARNs after 2 days and FAILs after 7.

## Related

`pi-recovery.md` (sections 0.5, 1 and 6), `m4-authentik.md` (section 6), `rotate-secrets.md`, `alerting.md`, `ca-backup.md`, `secrets-ssm.md`. Design record: ADR-015 in the Obsidian vault (Decisions).
