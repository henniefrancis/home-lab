#!/usr/bin/env bash
# shellcheck shell=bash
# Signed-commit verification for deploy.sh (SEC-M7). Source it; do not execute it.
#
# The Pi only deploys a commit whose SSH signature verifies against an allowed-signers file that lives OUTSIDE the checkout
# (default /etc/home-lab/allowed_signers, owned by root, 0644, in a root-owned directory), so a pushed commit cannot change who
# is trusted. Fails closed: a missing, empty, placeholder-only, symlinked or wrongly owned file, a missing ssh-keygen, an
# unsigned commit, a commit signed by another key, or any git error is a refusal.
#
# signers_problem <file>                                print why the file cannot be trusted; return 1 if it can be, 0 if there is a problem
# allowed_signers_usable <file>                          return 0 if signers_problem finds nothing
# verify_signed_commit <repo> <rev> <allowed_signers_file>   return 0 only if <rev> carries a valid signature by a listed key
#
# "Owned by root" means owned by the user running the check: deploy.sh and preflight.sh run as root, so on the Pi that is root. (The
# self-tests run as an ordinary user with their own temp files and test the root case in a root-only part.)
# Git runs with core.hooksPath=/dev/null: no hook of the checkout can run, even if the tree were writable (defence in depth, NEW-1).
#
# Owner setup is in docs/runbooks/m2-pi-setup.md (signing key) and config/allowed_signers.example (format).

# _owned_by_me_and_closed <path>: owned by the current user and not writable by group or other.
_owned_by_me_and_closed() {
  local own mode
  own="$(stat -c '%u' "$1" 2> /dev/null)" || return 1
  mode="$(stat -c '%a' "$1" 2> /dev/null)" || return 1
  [ "$own" = "$(id -u)" ] && [ $((8#$mode & 8#022)) -eq 0 ]
}

signers_problem() {
  local f="$1" body
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    echo "$f is missing or is a symlink"
    return 0
  fi
  _owned_by_me_and_closed "$f" || {
    echo "$f must be owned by root (the user running the deploy) and not writable by group or other"
    return 0
  }
  _owned_by_me_and_closed "$(dirname "$f")" || {
    echo "the directory of $f must be owned by root and not writable by group or other (a writable directory lets the file be replaced)"
    return 0
  }
  body="$(grep -Ev '^[[:space:]]*(#|$)' "$f" | tr -d '\r')" || body=""
  if grep -q 'REPLACE-WITH-YOUR-PUBLIC-KEY' <<< "$body"; then
    echo "$f still contains the placeholder line (REPLACE-WITH-YOUR-PUBLIC-KEY): remove that line, keep only real keys"
    return 0
  fi
  # a key line: principal, optional options, key type, base64 key. Comments and blank lines do not count.
  grep -Eq '^[^#[:space:]][^[:space:]]*[[:space:]]+(namespaces="[^"]*"[[:space:]]+)?(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp[0-9]+|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)[[:space:]]+AAAA[A-Za-z0-9+/=]{20,}' <<< "$body" || {
    echo "$f has no usable public key line (format: config/allowed_signers.example)"
    return 0
  }
  return 1
}

allowed_signers_usable() {
  ! signers_problem "$1" > /dev/null
}

verify_signed_commit() {
  local repo="$1" rev="$2" signers="$3" why
  command -v ssh-keygen > /dev/null 2>&1 || {
    echo "ERROR: ssh-keygen is missing (apt-get install openssh-client); cannot verify commit signatures." >&2
    return 1
  }
  if why="$(signers_problem "$signers")"; then
    echo "ERROR: $why; refusing to deploy unverified code." >&2
    return 1
  fi
  git -c core.hooksPath=/dev/null -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$signers" \
    -C "$repo" verify-commit "$rev" > /dev/null 2>&1 || {
    echo "ERROR: commit $(git -c core.hooksPath=/dev/null -C "$repo" rev-parse --short "$rev" 2> /dev/null || echo "$rev") has no valid signature from an allowed signer; refusing to deploy." >&2
    return 1
  }
  return 0
}
