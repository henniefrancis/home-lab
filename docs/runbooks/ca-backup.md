# Runbook: offline CA backup and restore test (K5)

Audience: the owner, on the laptop. Placeholders only. Companion: `m2-pi-setup.md` section 4 (create the CA) and 6 (sign), `pi-recovery.md` (section 3 needs the CA).

## What is at stake

The offline CA lives in `~/home-lab-ca` on the laptop and nowhere else unless you make a backup:

| File | What | Sensitive? |
|------|------|------------|
| `ca.key` | The CA private key, ECDSA P-384, encrypted with AES-256 under the CA passphrase | Yes, but only usable with the passphrase |
| `ca.crt` | The public CA certificate (`CN=home-lab-offline-ca`, 5 years); also in the HCP variable `ca_cert_pem` | No |
| `issued.tsv` | One row per certificate `sign.sh` issued (time, role, subject, serial, expiry, fingerprint) | Low |

Without `ca.key` and its passphrase nobody can sign a Pi certificate. Both Roles Anywhere certificates expire after 365 days, so a lost CA means a stalled renewal, then a stalled
secret fetch and ACME. The recovery from a lost CA is a new CA, a new `ca_cert_pem`, an apply and two new certificates (section 5): possible, but an outage you can avoid with a copy.

## 1. Make the backup [Laptop, once, then after every refresh trigger in section 2]

Two independent copies, in two different places:

**Copy A, the password manager.** Create one item, for example "home-lab offline CA backup", and attach the three files (`ca.key`, `ca.crt`, `issued.tsv`). Keep the CA
passphrase in its OWN item (the one `m2-pi-setup.md` step 4 told you to create), not in the same item as the attachment and never in a note next to the files.

**Copy B, a USB stick kept apart from the laptop** (a different room or a safe, not the laptop bag). Label it, and put on it only:

```bash
STICK=/e/home-lab-ca-backup            # the stick's mount point (Git Bash: /e, /f ...; WSL: /mnt/e; Linux: /media/$USER/...)
mkdir -p "$STICK" && cp -p ~/home-lab-ca/ca.key ~/home-lab-ca/ca.crt ~/home-lab-ca/issued.tsv "$STICK"/
(cd "$STICK" && sha256sum ca.key ca.crt issued.tsv > SHA256SUMS && cat SHA256SUMS)
```

- **Never write the passphrase onto the stick**, not even in a text file named something harmless. The key is encrypted; the stick must not hold the other half.
- Optional: encrypt the stick as a whole (BitLocker To Go, LUKS). `ca.key` already needs its passphrase, so this is a second layer, not a requirement.
- Do not copy the CA into a git work tree, a cloud-synced folder or a chat. `new-ca.sh` refuses a git work tree for the same reason.

Then run the restore test (section 3) against each copy once. A backup that has never been restored is a hope, not a backup.

## 2. When to refresh it

`ca.key` and `ca.crt` only change when you create a new CA, but `issued.tsv` changes on **every issuance**. So:

- **After every `scripts/pki/sign.sh` run** (the yearly renewals, a re-issue after a new generation, a rotation): replace `issued.tsv` in both copies, or simply repeat section 1. This is a step at the end of `m2-pi-setup.md` section 6.
- After any change of the CA passphrase or a new CA (replace all three files in both copies and update the passphrase item).
- At every recovery drill (`pi-recovery.md`, drill log): compare the checksums (section 3, step 1).

Without a fresh `issued.tsv` the backup still signs certificates; you only lose the record of what was issued.

## 3. Verify it [Laptop]

1. **Is the copy identical to the live CA?** `sha256sum ~/home-lab-ca/ca.key ~/home-lab-ca/ca.crt ~/home-lab-ca/issued.tsv` and the same for the restored copy (the restore test prints them too). A different
   `issued.tsv` hash means the backup is out of date: refresh it.
2. **Restore the copy into a scratch directory outside any repository, and test it.** From the password manager: download the three attachments into the scratch directory. From the stick: copy them.

   ```bash
   SCRATCH="$(mktemp -d)"                                   # outside the repository; deleted afterwards
   cp -p /e/home-lab-ca-backup/{ca.key,ca.crt,issued.tsv} "$SCRATCH"/     # or the files downloaded from the password manager
   cd /path/to/home-lab-new
   scripts/pki/test-ca-restore.sh --ca-dir "$SCRATCH"       # asks for the CA passphrase; nothing is echoed
   ```

   The script prints PASS or FAIL for each check and a final `RESULT: PASS` or `RESULT: FAIL`:

   - the three files are present, `ca.crt` is `CN=home-lab-offline-ca`, not expired (a WARN under 180 days: plan the CA rotation), and `ca.key` is passphrase-encrypted;
   - the passphrase decrypts `ca.key`, and `ca.crt` and `ca.key` are a pair (identical public keys);
   - the CA signs a throwaway certificate (a distinct CN `home-lab-restore-test-<random>`, valid 1 day, the same extensions as a real Pi certificate) and the new certificate verifies against `ca.crt` for client authentication;
   - the restored directory is byte-for-byte unchanged afterwards (checksummed before and after), so `issued.tsv` is never touched. `sign.sh` is deliberately not used: it appends to `issued.tsv`.

   The decrypted key is never written to disk: `openssl` reads the encrypted `ca.key` and takes the passphrase from an environment variable of that single command. The only files created are
   the throwaway key, CSR and certificate in a private temporary directory that is removed on exit. The throwaway certificate is worthless: no trust policy accepts its CN.
3. Compare the printed `ca.crt` SHA-256 fingerprint with the one you noted at step 4 of `m2-pi-setup.md` (and with the certificate in the trust anchor).
4. `rm -rf "$SCRATCH"`. Do the test again from the other copy.
5. Record it in the drill log (`pi-recovery.md`): date, which copy, PASS or FAIL.

If the result is FAIL, do not trust that copy. Common causes: a wrong passphrase (type it from the password manager, not from memory), a file truncated by a copy that was interrupted (compare with `SHA256SUMS`), a certificate and key from two different CAs.

## 4. Recovery when the laptop is lost [New laptop]

1. Restore the three files from copy A or copy B into `~/home-lab-ca` (mode 0700 directory), then run section 3 on it. Only continue on PASS.
2. Signing works as before (`m2-pi-setup.md` section 6, `pi-recovery.md` section 3).

## 5. When both the CA and every copy are gone

The Pi keeps working until its certificates expire (at most 365 days), but you can no longer renew them. Plan the replacement before that:

1. `scripts/pki/new-ca.sh` (a new CA, a new passphrase, a new backup: sections 1 to 3).
2. Put the new `ca.crt` into the gitignored `terraform/bootstrap/terraform.tfvars` as `ca_cert_pem` and apply with admin SSO (`m2-pi-setup.md` steps 8 and 9): the trust anchor now trusts the new CA and no longer the old one.
3. Bump `pki_generation` in the same apply if the old Pi keys should be retired (`pi-recovery.md` section 1, step 4), then issue both Pi certificates from the new CA (`m2-pi-setup.md` steps 5 to 7).

Related: `m2-pi-setup.md`, `pi-recovery.md`, `authentik-backup.md`.
