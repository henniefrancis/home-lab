# Runbook: release and deploy (the everyday loop)

Audience: the owner. Placeholders only. One-time setup of the signing key, `allowed_signers` and the root-owned checkout is in `m2-pi-setup.md` section 3.1; this page is the
short loop you repeat for every change (NEW-4, N3).

## The model in three lines

- The **Pi enforces signatures**: `sudo scripts/deploy.sh` merges and runs only a commit whose SSH signature verifies against `/etc/home-lab/allowed_signers`.
- **GitHub does not require signed commits.** Agents and tools commit normally (unsigned). You sign **one release commit per deploy**.
- A signature attests the **whole tree** and its history of parents. An unsigned commit under your signed one is deployed too. Read before you sign.

## Everyday loop

```text
change -> commit (unsigned is fine) -> you review the diff -> you sign a release commit -> push -> sudo scripts/deploy.sh (on the Pi)
```

On the laptop:

```bash
git fetch origin && git status                       # a clean tree, on main, up to date
git log --oneline <last-deployed>..HEAD              # what is about to ship, commit by commit
git diff <last-deployed>..HEAD                       # THE review: every line since the last deployed release, agent-written code included
bash scripts/test-ops-scripts.sh && bash scripts/test-set-secret.sh && bash scripts/test-aws-preflight.sh   # (the same checks CI runs)
git commit --allow-empty -S -m "Release: <what changed>"      # the signed release commit: signature covers the tree and every parent
git log --format='%h %G? %s' -3                      # the top line must show G (good signature)
git push
```

`<last-deployed>` is the release commit from the previous deploy (`git log --format='%h %G? %s' | grep ' G '` lists the signed ones; on the Pi,
`sudo git -C /opt/home-lab log -1 --format=%h` prints the deployed commit). If you are unsure, review `git diff` against the last release you remember deploying, not less.

On the Pi:

```bash
cd /opt/home-lab
sudo scripts/deploy.sh                 # fetch, verify the signature BEFORE merging, fast-forward only, secrets, compose up, health, certificate expiry
```

Step 1 prints `HEAD <sha>: signature verified against /etc/home-lab/allowed_signers`. Never run `git pull` on the Pi (it would skip the signature check and the checkout is
root-owned anyway); use `sudo git -C /opt/home-lab <command>` for read-only git queries (`status`, `log`, `diff`).

What stops a deploy, all by design and fail-closed (nothing is merged or started):

| Message | Meaning and fix |
|---------|-----------------|
| `the fetched commit is not signed by an allowed signer` | The pushed tip is unsigned or signed by another key (also: a GitHub web merge). Sign a release commit on top and push again. |
| `<path> is not root-owned or is writable by group/other` | The checkout is not clean root-owned (for example someone ran git as the login user): `sudo chown -R root:root /opt/home-lab && sudo chmod -R go-w /opt/home-lab`, then find out how it happened. |
| `... still contains the placeholder line` or `no usable public key` | `/etc/home-lab/allowed_signers` is not set up (m2-pi-setup.md 3.1). |
| `the checkout is not on a branch` | Detached HEAD on the Pi: `sudo git -C /opt/home-lab checkout main`. |
| `already up to date` with an older commit on origin | Rollback attempts are ignored (`--ff-only`). To go back on purpose, push a new signed commit that reverts. |

## Dependabot and GitHub-made commits

The merge button, squash merge, web edits and Dependabot pull requests create commits that GitHub signs with ITS key. The Pi does not trust that key (adding it would trust
everyone who can click merge; do not), so a tip made by GitHub is refused. Never deploy a GitHub-made commit directly. Either of these flows works:

**A. Merge locally (preferred).**

```bash
git fetch origin
git switch main && git pull --ff-only
git merge --no-ff origin/dependabot/<branch> -m "Merge dependency updates"     # or: git merge --ff-only / git cherry-pick <sha>
# review: git diff <last-deployed>..HEAD   (image digests, versions, and that CI is green on the PR)
git commit --allow-empty -S -m "Release: dependency updates"
git push
```

The PR closes by itself once its commits are on `main`. Then `sudo scripts/deploy.sh` on the Pi.

**B. Let it land through GitHub, then sign on top.** Merge the PR on GitHub (the tip is now GitHub-signed and NOT deployable), then on the laptop
`git pull --ff-only`, review `git diff <last-deployed>..HEAD`, `git commit --allow-empty -S -m "Release: ..."`, `git push`. Only the new signed tip is deployed.

Dependabot waits a few days after an upstream release before it proposes a version update (cooldown, N10); security updates are not delayed. Review each image PR: Dependabot
rewrites tag and digest together, and `scripts/scan-images.sh` shows what the new image carries.

## Pre-sign checklist (one screen)

1. `git diff <last-deployed>..HEAD` read in full, including files no agent was asked to touch (`scripts/`, `.github/`, `traefik/dynamic/`, `compose.yaml`, `config/`).
2. CI is green on the tip you are about to sign (`checks` and `secret-scan`).
3. No real domain, account ID, zone ID, address or secret in the diff (CI scans, you glance).
4. The release commit shows `G` in `git log --format='%h %G?'`.

## Rollback

Push a new signed commit that reverts the change, then `sudo scripts/deploy.sh`. For a broken stack right now: `sudo scripts/deploy.sh --offline` restarts from the last-good
secrets and the current checkout (it still verifies the signature of the checked-out commit).
