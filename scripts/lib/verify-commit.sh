#!/usr/bin/env bash
# shellcheck shell=bash
# Signed-commit verification for deploy.sh (SEC-M7). Source it; do not execute it.
#
# The Pi only deploys a commit whose SSH signature verifies against an allowed-signers file that lives OUTSIDE the checkout
# (default /etc/home-lab/allowed_signers, root 0644), so a pushed commit cannot change who is trusted. Fails closed: a missing,
# empty or placeholder-only file, a missing ssh-keygen, an unsigned commit, a commit signed by another key, or any git error
# is a refusal.
#
# verify_signed_commit <repo> <rev> <allowed_signers_file>   return 0 only if <rev> carries a valid signature by a listed key
#
# Owner setup is in docs/runbooks/m2-pi-setup.md (signing key) and config/allowed_signers.example (format).

# allowed_signers_usable <file>: the file exists, is not writable by group/other, and has at least one real key line.
allowed_signers_usable() {
  local f="$1" mode
  [ -f "$f" ] || return 1
  mode="$(stat -c '%a' "$f" 2> /dev/null)" || return 1
  [ $((8#$mode & 8#022)) -eq 0 ] || return 1
  # a key line: principal, optional options, key type, base64 key. Comments and the example placeholder do not count.
  grep -Eq '^[^#[:space:]][^[:space:]]*[[:space:]]+(namespaces="[^"]*"[[:space:]]+)?(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp[0-9]+|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)[[:space:]]+AAAA[A-Za-z0-9+/=]{20,}' "$f" &&
    ! grep -q 'REPLACE-WITH-YOUR-PUBLIC-KEY' "$f"
}

verify_signed_commit() {
  local repo="$1" rev="$2" signers="$3"
  command -v ssh-keygen > /dev/null 2>&1 || {
    echo "ERROR: ssh-keygen is missing (apt-get install openssh-client); cannot verify commit signatures." >&2
    return 1
  }
  allowed_signers_usable "$signers" || {
    echo "ERROR: $signers is missing, writable by others, or has no usable public key; refusing to deploy unverified code." >&2
    return 1
  }
  git -c safe.directory="$repo" -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$signers" \
    -C "$repo" verify-commit "$rev" > /dev/null 2>&1 || {
    echo "ERROR: commit $(git -c safe.directory="$repo" -C "$repo" rev-parse --short "$rev" 2> /dev/null || echo "$rev") has no valid signature from an allowed signer; refusing to deploy." >&2
    return 1
  }
  return 0
}
