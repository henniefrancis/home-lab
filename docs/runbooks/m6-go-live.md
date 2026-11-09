# Runbook: M6 go-live (production certificate, then public)

One ordered list. Every step has a **Verify** and a **Rollback**. Do not start a step before the previous one verifies. Placeholders only: `<domain>`, `<repo>`, `<owner>`.
Where each step is run: **Laptop**, **Pi**, **GitHub** (browser), **HCP** (browser).

Why this order: the production certificate and its alerting come first (an expired certificate behind a long HSTS is a hard outage); the repository goes public only when the
history is scanned and the Pi no longer needs a private deploy key; the protections are switched on within minutes of going public, because a public repo without them is exposed.

Related: `alerting.md` (K4), `release-and-deploy.md`, `sec-remediation-apply-order.md` section 7 (the settings list), `m4-authentik.md` section 8, `pi-recovery.md`.

## 0. Preconditions (all must be true)

- `terraform/bootstrap` applied with `alert_email`, the SNS subscription confirmed, `ALERT_TOPIC_ARN` in `/etc/home-lab/aws.env`, the units installed (`sudo scripts/bootstrap.sh`; preflight `systemd-units` PASS), and `sudo scripts/alert.sh test` **delivered an email you actually received** (`alerting.md`).
- `sudo scripts/preflight.sh --stage full` on the Pi: 0 FAIL. Expected WARN while still on staging: `acme-env`. `acme-env-match` must be PASS.
- CI (`checks`, `secret-scan`) is green on the current `main` tip.
- K1 (the other project's OIDC role pinned) is done and re-checked, or the owner has accepted the risk in the TAM note with a date.
- You have 2 free hours and are at home (Tailscale down means no remote path; break-glass only opens the Traefik dashboard).

## 1. Switch ACME to production (Laptop, then Pi)

1. Edit `config/lab.env`:
   ```text
   ACME_ENV=prod
   ACME_CA_SERVER=https://acme-v02.api.letsencrypt.org/directory
   ```
   Commit, review the diff (only these two lines), sign a release commit, push, wait for green CI, then on the Pi `sudo scripts/deploy.sh --recreate traefik` (`release-and-deploy.md`).
   The staging store `/apps/traefik/letsencrypt/acme-staging.json` is **kept**: Traefik writes production data to `acme-prod.json` (the file name follows `ACME_ENV`).
2. **Verify:** `sudo docker logs traefik --since 10m | grep -i -E 'acme|certificate|error'` shows an obtained certificate and no rate-limit error;
   `sudo ls -l /apps/traefik/letsencrypt/` lists `acme-prod.json` (mode 0600) next to `acme-staging.json`; `sudo scripts/preflight.sh --stage full` no longer warns `acme-env`.
   Issuance by DNS-01 can take a few minutes (the Roles Anywhere helper signs the Route 53 change).
3. **Rollback:** revert the two lines (signed release, push, `sudo scripts/deploy.sh --recreate traefik`). Traefik goes back to the kept staging store, so there is no gap. Production issuance counts against Let's Encrypt limits; do not flip back and forth more than twice a day.

## 2. Verify the chain issuer (Pi or Laptop)

1. From a LAN or tailnet machine: `openssl s_client -connect dashboard.<domain>:443 -servername dashboard.<domain> </dev/null 2>/dev/null | openssl x509 -noout -issuer -dates -ext subjectAltName`.
   On the Pi the same is `sudo scripts/served-cert-check.sh`.
2. **Verify:** the issuer is a production Let's Encrypt intermediate (an issuer name that does **not** contain "STAGING" or "Fake"); the SAN lists `*.<domain>`; the days left are about 90 (or less if Let's Encrypt now issues shorter lifetimes, the K4 thresholds still apply);
   a browser on the LAN shows the padlock with no warning on `https://dashboard.<domain>`.
3. **Rollback:** as step 1. Do not go on to step 3 until this verifies.

## 3. CAA `accounturi` (Laptop and HCP, Terraform)

Pins issuance to your Let's Encrypt account (SEC-L5). The account URI is public but account-specific, so it lives in the HCP workspace, not in git.

1. On the Pi read the URI without printing the key: `sudo jq -r '.le.Account.Registration.uri' /apps/traefik/letsencrypt/acme-prod.json` (the output is a `https://acme-v02.api.letsencrypt.org/acme/acct/<id>` URL).
2. HCP workspace `home-lab`: add the Terraform variable `acme_account_uri` with that URL (`terraform/edge/workspace-variables.example.md`). Queue a plan, **read it**: the only change is the apex `CAA` record gaining `accounturi=...` on both the `issue` and `issuewild` values. Apply.
3. **Verify:** `dig +short CAA <domain>` (or `nslookup -type=CAA <domain>`) shows `letsencrypt.org; validationmethods=dns-01; accounturi=...`; force a renewal check later by watching `alerting.md` (the first renewal at about 60 days must still succeed).
4. **Rollback:** remove the variable (set it to null or delete it) and apply: the CAA reverts to `validationmethods=dns-01` without the account pin. If a renewal fails with a CAA error, do this first, renew, then re-apply with the corrected URI.

## 4. Raise HSTS in steps (Laptop, then Pi) - only after K4 alerting is live

HSTS is `stsSeconds` in `traefik/dynamic/middlewares.yml` (`security-headers`). A long value turns an expired certificate into a total lockout for browsers that saw it, so raise it only when step 0 is true, one step at a time, each as a reviewed and signed release.
**Gate for every raise (b and c):** before you edit anything, run `sudo scripts/alert.sh test` and confirm the mail **arrives** (the daily check only proves that the check ran, not that a mail can reach you). The monthly heartbeat mail received within the last 7 days counts too. No delivered test within 7 days, no raise.

| Step | `stsSeconds` | Wait before the next step |
|---|---|---|
| a | `300` (today) | production certificate verified (step 2) |
| b | `86400` (1 day) | at least 2 days with the K4 daily check green |
| c | `31536000` (1 year, SEC-L12) | at least 7 days at step b with no certificate alert |

Keep `stsPreload: false`; do not submit the domain to a preload list.

1. Edit the value, commit, sign, push, wait for CI, `sudo scripts/deploy.sh --only traefik` (the dynamic files are copied on deploy; Traefik reloads them).
2. **Verify:** `curl -sI https://dashboard.<domain>/ | grep -i strict-transport-security` shows `max-age=<the new value>; includeSubDomains`; `sudo scripts/alert.sh check` exits 0; `sudo scripts/served-cert-check.sh` prints `[PASS]` with a production issuer.
3. **Rollback:** lower the value in another signed release. Browsers keep what they already cached until it expires (up to the old max-age), which is why the steps are small and the alert comes first.

## 5. Retire `akadmin` (Browser)

Follow `m4-authentik.md` section 8, items 1 and 2: create your named admin with MFA, confirm it works, **deactivate** `akadmin`, and make sure `authentik/bootstrap-password` is UNSET (`scripts/set-secret.sh --unset authentik/bootstrap-password`, then `sudo scripts/deploy.sh --recreate authentik`).
- **Verify:** log in as your named user and reach `https://dashboard.<domain>`; `akadmin` shows as inactive in Directory, Users; `sudo test ! -s /apps/secrets/authentik/bootstrap-password && echo empty`.
- **Rollback:** reactivate `akadmin` from your named admin account, or use the recovery key command in `m4-authentik.md` section 6 (it works for any user).

## 6. Reboot the Pi (Pi)

`sudo reboot`. This also ends the old Raspberry Pi Connect session that kept the `docker` group (SEC-M3) and proves the boot path and the break-glass reset.
- **Verify** after 3 to 5 minutes (over Tailscale or the LAN): `sudo docker compose -p home-lab ps` all healthy; `sudo scripts/preflight.sh --stage full` 0 FAIL and `login-docker-group` PASS; `sudo scripts/breakglass.sh status` says off;
  `https://dashboard.<domain>` loads; `sudo scripts/alert.sh check` exits 0; `timedatectl` shows the clock synchronised.
- **Rollback:** nothing to roll back; if a container stays down, `sudo scripts/deploy.sh --offline`, then `pi-recovery.md`. If the clock is wrong after boot (no RTC), fix NTP before anything else.

## 7. A new signed release, green on its exact commit (Laptop, Pi)

1. On a clean `main`: `git diff <last-deployed>..HEAD` read in full (`release-and-deploy.md`, pre-sign checklist). Wait until `checks` and `secret-scan` are green **on the commit you will sign** (not an earlier one; the previous release was signed while CI was red).
2. `git commit --allow-empty -S -m "Release: M6 go-live"`, `git log --format='%h %G? %s' -3` shows `G`, push, **wait for CI on that exact SHA**, then `sudo scripts/deploy.sh` on the Pi.
3. **Verify:** the Pi prints `HEAD <sha>: signature verified`; `<sha>` equals the commit CI went green on (`git rev-parse HEAD` on the laptop, `sudo git -C /opt/home-lab rev-parse HEAD` on the Pi). Write this SHA down: it is the commit that goes public. **No more commits until the repo is public.**
4. **Rollback:** a new signed revert commit, then deploy.

## 8. K2: disconnect the old local folder (Laptop, owner)

Any old local working copy from before the history reset (`<old-working-copy>` below) may still point at the same GitHub remote and hold the pre-reset history. A push, a tag or a force-push from it would publish that history.
- Do: in that folder run `git remote remove origin` (or archive and delete the folder after a final check that nothing in it is still needed).
- **Verify:** `git -C <old-working-copy> remote -v` prints nothing (or the folder is gone). `git ls-remote origin` from the **new** clone still works.
- **Rollback:** `git remote add origin <url>`, but only if you really need it and only after the repo is public and the ruleset exists.

## 9. K3: private denylist and gitleaks on the exact SHA (Laptop, owner)

Scan a **fresh clone**, not your working folder: the working folder holds real, gitignored files (`terraform.tfvars`, `adopt-snapshot/`) that a directory scan would flag or tempt you to allow-list.
1. Copy `.gitleaks-private.toml.example` to `.gitleaks-private.toml` (gitignored) and fill it with your real domain, account ID, zone ID, Pi and tailnet addresses, personal emails and names.
2. Make the clone of the exact commit from step 7 (`<sha>`): `scan="$(mktemp -d)" && git clone --no-local . "$scan" && git -C "$scan" switch --detach <sha>`. Copy `.gitleaks-private.toml` into it.
3. In the clone run `bash scripts/check-private-denylist.sh` (it scans every commit on every ref with your private rules; exit 0 = clean, 2 = not configured) and the public-rules scan exactly as `.github/workflows/secret-scan.yml` does: `img="$(awk '$1=="FROM" && $4=="gitleaks" {print $2}' ci/images/gitleaks/Dockerfile)"`, then `docker run --rm -v "$PWD:/repo" "$img" git /repo --config /repo/.gitleaks.toml --redact --no-banner` and the same with `dir` instead of `git`.
4. **Commit metadata:** `git -C "$scan" log --all --format='%an %ae | %cn %ce' | sort -u` must show only your GitHub noreply address and the names you want public (author and committer names and emails are public once the repo is).
5. **Verify:** all scans report zero findings, the metadata list is what you expect, and the CI `secret-scan` run for that SHA is green. Any finding: stop, fix in a new commit **and repeat from step 7** (a new SHA needs a new green CI and a new signed release), or rewrite history before going public, never after.
6. **Rollback:** not applicable (read only). Delete the clone (`rm -rf "$scan"`).

## 10. Make the repository public (GitHub, owner)

Settings, General, Danger Zone, Change visibility, Public. Do steps 10 to 14 back to back, within minutes; keep the settings pages open in tabs beforehand.
Right after the flip also set (Settings, Actions, General; `sec-remediation-apply-order.md` section 7): **approval for all outside collaborators' fork pull-request runs**, the **default workflow token read-only**, and **allow only GitHub-owned actions and the pinned third-party actions** (or require SHA pinning).
- **Verify:** `git ls-remote https://github.com/<owner>/<repo>.git` works from a machine with no GitHub login; the Actions settings show the three values above.
- **Rollback:** Change visibility back to Private immediately. Anything cloned or cached while public must be treated as published: if a finding appears after the flip, rotate the secret, not just the history.
  **After step 12 this rollback also breaks the Pi:** it no longer has a deploy key and its HTTPS fetch of a private repo fails (deploys then fail closed, nothing unsigned can run). Either add a new deploy key and the SSH remote (step 12 rollback) or run `sudo scripts/deploy.sh --no-git` until the repo is public again.

## 11. Rulesets on `main` immediately (GitHub)

Use **two rulesets**, so that the protection that must never be skipped has no way around it, and the one that would otherwise block your own push has exactly one.
Settings, Rules, Rulesets, New branch ruleset, target `main`, enforcement Active.
1. **"main: no force-push, no deletion"**: rules *Block force pushes* and *Restrict deletions*. **Bypass list: empty.**
2. **"main: required checks"**: rule *Require status checks to pass* with the checks `checks` and `secret-scan` (exact job names; they only appear in the picker after a green run on `main`). **Bypass list: add "Repository admin" (the repository role) and set the bypass mode to "Always allow".**
   Why: your release flow pushes a signed commit directly to `main` and only then waits for CI (step 7). A required check cannot be satisfied by a commit that has no check run yet, so without a bypass the push would be rejected, and the "fix" people reach for is switching the rule off. The `ci` workflow also skips docs-only pushes (`paths-ignore`), so the required check would never appear for them.
   The bypass is for you as the repository admin; CI and agents have no admin role.
3. Do **not** require signed commits and do not require pull requests (`sec-remediation-apply-order.md` section 7): the Pi enforces signatures (`deploy.sh`), agents commit unsigned, and the GitHub merge button signs with a key the Pi does not trust.

GitHub documentation: [Creating rulesets for a repository](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository) (the "Bypass list" lets you add "Repository admins, organization owners, and enterprise owners", among other actors) and [Available rules for rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) (*Block force pushes*; *Restrict deletions*: "only users with bypass permissions can delete"). Neither page says how several rulesets combine, nor whether a required check blocks a direct push; that is why the first ruleset has no bypass at all and why the Verify below tests the real behaviour. Re-read both pages when you create the rulesets: the labels in the GitHub UI change.
- **Verify, all four:**
  1. A normal direct push still works: on the laptop a trivial signed commit (`git commit --allow-empty -S -m "ruleset check"`) then `git push` succeeds. If it is rejected, the bypass is not on the right ruleset or your role is not admin: fix that before anything else.
  2. A force-push is refused, also for you as admin: from a scratch clone `git push --force origin HEAD~1:main` is rejected.
  3. Deleting `main` is rejected: `git push origin :main` from a scratch clone.
  4. The two check names show as required, and CI on that commit goes green (docs-only commits skip CI by design).
  The empty commit from check 1 is a real release commit: deploy it or let the next release carry it.
- **Rollback:** set the offending ruleset to Disabled (not delete) while you fix it. If only the push in Verify 1 fails, disable only ruleset 2 until the bypass is right; keep ruleset 1 on. Never leave the repo public without ruleset 1.

## 12. Pi: switch the remote to HTTPS and remove the deploy key (Pi, GitHub)

This must follow step 10: an HTTPS clone with no credentials only works for a public repo. The checkout is root-owned, so use `sudo git`.
1. `sudo git -C /opt/home-lab remote set-url origin https://github.com/<owner>/<repo>.git`
2. GitHub, Settings, Deploy keys: delete the Pi's key. On the Pi remove the key file and its SSH config entry if you added one (`m2-pi-setup.md`).
3. **Verify:** `sudo scripts/deploy.sh` fetches over HTTPS (`signature verified` printed, no SSH prompt); `sudo git -C /opt/home-lab remote -v` shows only the https URL; the Deploy keys list is empty.
4. **Rollback:** add a new deploy key and set the SSH URL again (`m2-pi-setup.md`); never reuse the deleted key.

## 13. Secret scanning and push protection (GitHub)

Settings, Code security: enable **Secret scanning** and **Push protection**; also Dependabot alerts and security updates if not already on.
- **Verify:** both show Enabled; `git push` of a file containing the GitHub documentation's example token pattern to a scratch branch is blocked (use a throwaway branch and delete it; never a real secret).
- **Rollback:** disable only if push protection blocks a documented false positive, with a bypass reason, and re-enable at once.

## 14. Private vulnerability reporting (GitHub)

Settings, Code security, Private vulnerability reporting: Enable. `SECURITY.md` tells reporters to use it.
- **Verify:** the Security tab shows "Report a vulnerability".
- **Rollback:** disable, and add a contact line to `SECURITY.md` in the next release.

## After going public

- T5b (Access Analyzer tightening of the four roles) one week later (owner decision).
- Record in the Obsidian TAM note: date public, SHA, ruleset enabled, deploy key removed, K2 done.
- The remaining TAM items still apply before sign-off: K5 (recovery drill, CA backup restore test, `pg_dump` off the Pi), the Q20 tabletop.
- Watch the first email alert path for real: `sudo scripts/alert.sh check` weekly by hand for the first month, and the first automatic renewal (about 60 days after issue).
