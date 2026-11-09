#!/usr/bin/env bash
# test-deploy.sh - self-test of scripts/deploy.sh and the signed-commit trust chain with REAL git and ssh-keygen (SEC-M3, SEC-M7,
# NEW-1, NEW-5, NEW-6, coverage gap "signed deploy in CI"). Needs root (it chowns trees to other users), git, ssh-keygen, find.
# Everything happens in a temp directory; docker is a stub that only logs, aws is a stub that fails loudly (nothing may call it),
# (the copy of THIS repo is listed with safe.directory=* because the repo may belong to the CI user while the test runs as root.)
# fetch-secrets.sh inside the throwaway checkout is replaced by a stub. No network, no AWS, no real secret.
# CI runs it as: sudo -E env REQUIRE_ROOT=1 bash scripts/test-deploy.sh      Locally: in a throwaway Linux container as root.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose: $1, $2 expand in the child shell
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  fails=$((fails + 1))
}
check() { # check <description> <command...>
  local d="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

if [ "$(id -u)" -ne 0 ]; then
  if [ "${REQUIRE_ROOT:-0}" = 1 ]; then
    echo "FAIL  this test needs root and REQUIRE_ROOT=1 is set (CI must not skip it)"
    exit 1
  fi
  echo "SKIP  needs root (run: sudo -E bash $0)"
  exit 0
fi
for t in git ssh-keygen find tar; do
  command -v "$t" > /dev/null || {
    echo "$t is required" >&2
    exit 2
  }
done

umask 022
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
chmod 755 "$T"
export HOME="$T/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$T/stubbin" "$T/apps/secrets" "$T/dyn" "$T/pki"

# ---- stubs: docker logs its arguments, aws must never be called
printf '#!/bin/sh\necho "$@" >> "%s/docker.log"\nexit 0\n' "$T" > "$T/stubbin/docker"
printf '#!/bin/sh\necho "aws was called" >> "%s/aws-called"\nexit 97\n' "$T" > "$T/stubbin/aws"
chmod 755 "$T/stubbin/docker" "$T/stubbin/aws"
: > "$T/apps/secrets/runtime.env"

# ---- signing keys and the allowed-signers file (root-owned, in a root-owned directory)
mkdir -p "$T/keys" "$T/etc"
ssh-keygen -q -t ed25519 -N '' -C owner-test -f "$T/keys/owner" > /dev/null
ssh-keygen -q -t ed25519 -N '' -C other-test -f "$T/keys/other" > /dev/null
printf 'owner@example.invalid namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$T/keys/owner.pub")" > "$T/etc/allowed_signers"
chmod 644 "$T/etc/allowed_signers"
chmod 755 "$T/etc"

# ---- a throwaway "checkout": every tracked or new file of this repo, a stub fetch-secrets.sh, APPS_ROOT in the temp dir
seed="$T/seed"
mkdir -p "$seed"
(cd "$REPO" && git -c safe.directory='*' ls-files --cached --others --exclude-standard -z | while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done | tar --null -T - -cf -) | tar -C "$seed" -xf -
sed -i "s#^APPS_ROOT=.*#APPS_ROOT=$T/apps#" "$seed/config/lab.env"
printf '#!/bin/sh\necho "stub fetch-secrets" >> "%s/fetch.log"\nexit 0\n' "$T" > "$seed/scripts/fetch-secrets.sh"
chmod 755 "$seed/scripts/fetch-secrets.sh"

G() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c gpg.format=ssh "$@"; }
git init -q -b main "$seed"
git -C "$seed" add -A
G -C "$seed" -c "user.signingkey=$T/keys/owner.pub" commit -q -S -m "seed signed by owner"
git init -q --bare -b main "$T/origin.git"
git -C "$seed" push -q "$T/origin.git" main
git clone -q "$T/origin.git" "$T/dev" 2> /dev/null

publish() { # publish <message> [key]: a new commit in the dev clone pushed to origin (unsigned without a key). -f: the history test rewinds origin.
  echo "$1" >> "$T/dev/CHANGELOG-TEST"
  git -C "$T/dev" add -A
  if [ -n "${2:-}" ]; then
    G -C "$T/dev" -c "user.signingkey=$T/keys/$2.pub" commit -q -S -m "$1"
  else
    G -C "$T/dev" commit -q -m "$1"
  fi
  git -C "$T/dev" push -q -f origin main 2> /dev/null
}
fresh() { # fresh: origin gets a signed baseline tip, then a clean root-owned checkout of it at $T/work, plus clean logs
  publish "signed baseline" owner
  rm -rf "$T/work" "$T/docker.log" "$T/fetch.log" "$T/aws-called" "$T/dyn"/* "$T/hook-ran"
  git clone -q "$T/origin.git" "$T/work" 2> /dev/null
  chown -R root:root "$T/work"
}
rc=0
dep() { # dep <deploy args...>: run the checkout's deploy.sh as root; output in $T/o, exit code in $rc
  rc=0
  rm -f "$T/docker.log"
  env PATH="$T/stubbin:$PATH" HOME_LAB_ALLOWED_SIGNERS="$T/etc/allowed_signers" TRAEFIK_DYNAMIC_DIR="$T/dyn" HOME_LAB_PKI_DIR="$T/pki" \
    bash "$T/work/scripts/deploy.sh" "$@" > "$T/o" 2>&1 || rc=$?
}
head_of() { git -C "$T/work" rev-parse HEAD; }
docker_ran() { [ -s "$T/docker.log" ]; }

# ======================================================================== signed commits (SEC-M7)
fresh
dep --no-git
check "signed HEAD, --no-git: deployed, signature verified" bash -c 'test "$1" -eq 0 && grep -q "signature verified" "$2"' _ "$rc" "$T/o"
check "the stub docker was used and the stub aws never" bash -c 'test -s "$1/docker.log" && test ! -e "$1/aws-called"' _ "$T"
dep --offline
check "signed HEAD, --offline: deployed" test "$rc" -eq 0

fresh
before="$(head_of)"
publish "signed update" owner
dep
check "full deploy fetches, verifies and merges a newer signed tip" bash -c 'test "$1" -eq 0 && test "$(git -C "$2" rev-parse HEAD)" != "$3" && grep -q "signature verified" "$4"' _ "$rc" "$T/work" "$before" "$T/o"

fresh
before="$(head_of)"
publish "unsigned tip"
dep
check "origin tip UNSIGNED: refused, nothing merged, docker never called" bash -c 'test "$1" -ne 0 && test "$(git -C "$2" rev-parse HEAD)" = "$3" && ! test -s "$4/docker.log"' _ "$rc" "$T/work" "$before" "$T"

fresh
before="$(head_of)"
publish "tip signed by another key" other
dep
check "origin tip signed by a key that is not allowed: refused, nothing merged" bash -c 'test "$1" -ne 0 && test "$(git -C "$2" rev-parse HEAD)" = "$3" && ! test -s "$4/docker.log"' _ "$rc" "$T/work" "$before" "$T"

fresh
before="$(head_of)"
publish "unsigned middle"
publish "signed over unsigned" owner
dep
check "an unsigned commit UNDER a signed tip is deployed (the signature covers the tree and the parents; review before signing)" bash -c 'test "$1" -eq 0 && test "$(git -C "$2" rev-parse HEAD)" != "$3" && grep -q "signature verified" "$4"' _ "$rc" "$T/work" "$before" "$T/o"

fresh
before="$(head_of)"
publish "newer signed" owner
newer="$(git -C "$T/dev" rev-parse HEAD)"
dep
check "(set-up) the newer commit was deployed" test "$(head_of)" = "$newer"
git -C "$T/dev" push -q -f origin "$before:refs/heads/main" 2> /dev/null
dep
check "origin rewound to an older signed commit: no downgrade, HEAD unchanged" bash -c 'test "$1" -eq 0 && test "$(git -C "$2" rev-parse HEAD)" = "$3"' _ "$rc" "$T/work" "$newer"

fresh
git -C "$T/work" checkout -q --detach
dep
check "detached HEAD, full deploy: refused (not on a branch)" bash -c 'test "$1" -ne 0 && grep -q "not on a branch" "$2" && ! test -s "$3/docker.log"' _ "$rc" "$T/o" "$T"
dep --no-git
check "detached signed HEAD with --no-git still deploys" test "$rc" -eq 0

fresh
publish "unsigned for local test"
git -C "$T/work" fetch -q origin main
git -C "$T/work" merge -q --ff-only FETCH_HEAD
dep --no-git
check "a local UNSIGNED HEAD is refused with --no-git" bash -c 'test "$1" -ne 0 && ! test -s "$2/docker.log"' _ "$rc" "$T"
dep --offline
check "a local UNSIGNED HEAD is refused with --offline" bash -c 'test "$1" -ne 0 && ! test -s "$2/docker.log"' _ "$rc" "$T"

fresh
printf '[core]\n\tsshCommand = /bin/true\n[gpg "ssh"]\n\tprogram = /bin/true\n' >> "$T/work/.git/config"
publish "unsigned behind a lying repo config"
dep
check "gpg.ssh.program in the repository config cannot turn an unsigned tip into a verified one" bash -c 'test "$1" -ne 0 && ! test -s "$2/docker.log"' _ "$rc" "$T"

# ======================================================================== checkout ownership and hooks (NEW-1)
fresh
publish "signed for the hook test" owner
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$T" > "$T/work/.git/hooks/post-merge"
chmod 755 "$T/work/.git/hooks/post-merge"
dep
check "a root-owned post-merge hook does NOT run (core.hooksPath=/dev/null)" bash -c 'test "$1" -eq 0 && ! test -e "$2/hook-ran"' _ "$rc" "$T"

fresh
publish "signed for the ownership test" owner
chown -R 1000:1000 "$T/work"
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$T" > "$T/work/.git/hooks/post-merge"
chmod 755 "$T/work/.git/hooks/post-merge"
dep
check "checkout and .git owned by uid 1000: refused BEFORE any git call, no hook, no docker" bash -c 'test "$1" -ne 0 && grep -q "not root-owned" "$2" && ! test -e "$3/hook-ran" && ! test -s "$3/docker.log"' _ "$rc" "$T/o" "$T"
dep --no-git
check "the ownership check also covers --no-git" bash -c 'test "$1" -ne 0 && ! test -s "$2/docker.log"' _ "$rc" "$T"

fresh
chown 1000:1000 "$T/work/.git/config"
dep --no-git
check "only .git/config owned by uid 1000 (top directory root): refused" bash -c 'test "$1" -ne 0 && grep -q "not root-owned" "$2"' _ "$rc" "$T/o"

fresh
chmod o+w "$T/work/scripts/deploy.sh"
dep --no-git
check "deploy.sh itself writable by others: refused" bash -c 'test "$1" -ne 0 && grep -q "writable by group/other\|not root-owned" "$2"' _ "$rc" "$T/o"

fresh
chmod g+w "$T/work/.git/hooks"
dep --no-git
check ".git/hooks group-writable: refused" test "$rc" -ne 0

fresh
mv "$T/work/.git" "$T/work-gitdir"
ln -s "$T/work-gitdir" "$T/work/.git"
dep --no-git
check ".git is a symlink: refused" bash -c 'test "$1" -ne 0 && grep -q "symlink" "$2"' _ "$rc" "$T/o"
rm -f "$T/work/.git"
mv "$T/work-gitdir" "$T/work/.git"

fresh
dep --no-git
check "preflight's ownership test agrees on a clean checkout (root_tree_offender prints nothing)" bash -c '. "$1/scripts/lib/common.sh" && test -z "$(root_tree_offender "$2")"' _ "$REPO" "$T/work"
chown 1000 "$T/work/config/lab.env"
check "root_tree_offender names a file owned by someone else" bash -c '. "$1/scripts/lib/common.sh" && test "$(root_tree_offender "$2")" = "$2/config/lab.env"' _ "$REPO" "$T/work"

# ======================================================================== allowed_signers trust file (NEW-5, NEW-6, N9)
fresh
publish "signed for the signers test" owner
keyline="$(cat "$T/etc/allowed_signers")"
setsigners() { # setsigners <content> [mode] [owner]
  printf '%s\n' "$1" > "$T/etc/allowed_signers"
  chmod "${2:-644}" "$T/etc/allowed_signers"
  chown "${3:-0}:${3:-0}" "$T/etc/allowed_signers"
}
setsigners "$keyline" 644 1000
dep --no-git
check "allowed_signers owned by uid 1000 (mode 644): refused (NEW-6)" bash -c 'test "$1" -ne 0 && grep -q "owned by root" "$2" && ! test -s "$3/docker.log"' _ "$rc" "$T/o" "$T"
setsigners "$keyline" 644 0
chown 1000 "$T/etc"
dep --no-git
check "allowed_signers in a directory owned by uid 1000: refused (the file could be replaced)" bash -c 'test "$1" -ne 0 && grep -q "directory" "$2"' _ "$rc" "$T/o"
chown 0 "$T/etc"
chmod 777 "$T/etc"
dep --no-git
check "allowed_signers in a world-writable directory: refused" test "$rc" -ne 0
chmod 755 "$T/etc"
setsigners "$keyline" 664
dep --no-git
check "allowed_signers mode 664: refused" test "$rc" -ne 0
setsigners "$keyline" 600
dep --no-git
check "allowed_signers root-owned mode 600: accepted" test "$rc" -eq 0
setsigners "$keyline" 644
mv "$T/etc/allowed_signers" "$T/etc/real-signers"
ln -s "$T/etc/real-signers" "$T/etc/allowed_signers"
dep --no-git
check "allowed_signers as a symlink: refused" test "$rc" -ne 0
rm -f "$T/etc/allowed_signers"
mv "$T/etc/real-signers" "$T/etc/allowed_signers"

setsigners "owner@example.invalid namespaces=\"git\" ssh-ed25519 REPLACE-WITH-YOUR-PUBLIC-KEY
$keyline"
dep --no-git
check "placeholder line next to a real key: refused and the message says to remove the placeholder line (NEW-5)" bash -c 'test "$1" -ne 0 && grep -q "remove that line" "$2"' _ "$rc" "$T/o"
setsigners "# copy of config/allowed_signers.example: replace REPLACE-WITH-YOUR-PUBLIC-KEY with your key
$keyline"
dep --no-git
check "a COMMENT that merely mentions the placeholder does not block a real key (NEW-5)" test "$rc" -eq 0
setsigners "# only comments"
dep --no-git
check "comments only: refused with 'no usable public key'" bash -c 'test "$1" -ne 0 && grep -q "no usable public key" "$2"' _ "$rc" "$T/o"
setsigners "$keyline" 644
rm -f "$T/etc/allowed_signers"
dep --no-git
check "allowed_signers missing: refused" bash -c 'test "$1" -ne 0 && ! test -s "$2/docker.log"' _ "$rc" "$T"
setsigners "$keyline" 644

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll deploy checks passed\n'
