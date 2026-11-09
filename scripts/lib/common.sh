#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for the Pi-side and PKI scripts. Source it; do not execute it.
# Never log secret values from anything that sources this file.

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() { printf 'WARN: %s\n' "$*" >&2; }

info() { printf '%s\n' "$*"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "this step must run as root: sudo $0 ${*:-}"
}

# repo_dir <script path>: the repository root for a script in scripts/ or scripts/<sub>/.
repo_dir() {
  local d
  d="$(cd "$(dirname "$1")" && pwd)"
  while [ "$d" != "/" ] && [ ! -f "$d/config/lab.env" ]; do d="$(dirname "$d")"; done
  [ -f "$d/config/lab.env" ] || die "cannot locate the repository root (config/lab.env) from $1"
  printf '%s' "$d"
}

# lab_env_get <file> <KEY> [default]: read KEY from a KEY=VALUE file without sourcing it.
lab_env_get() {
  local v
  v="$(grep -E "^$2=" "$1" 2> /dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r')" || true
  printf '%s' "${v:-${3:-}}"
}

# ver_ge <have> <want>: true if version have >= want (sort -V).
ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

# root_tree_offender <dir>: print the first path below <dir> (the directory itself included) that is NOT owned by root, or that
# is writable by group or other (symlinks are skipped for the mode test: Linux reports them as 0777). Prints nothing when the
# tree is clean. Used by deploy.sh and preflight.sh (SEC-M3, NEW-1): root runs git and the scripts of this checkout, so a file
# that any other user can change is a local privilege escalation, whatever the commit signatures say.
root_tree_offender() {
  find "$1" \( -not -user root -o \( -not -type l -a -perm /022 \) \) -print -quit
}

# assert_root_tree <dir>: die unless <dir> is a plain git checkout whose whole tree, .git included, is root-owned and not
# writable by others. Git's own "dubious ownership" guard is NOT bypassed to get here (no safe.directory anywhere): a root-owned
# checkout needs none, and anything else is refused.
assert_root_tree() {
  local d="$1" bad
  [ -d "$d/.git" ] && [ ! -L "$d/.git" ] || die "$d/.git is missing, a symlink or a file (gitdir redirect); refusing to run git as root"
  bad="$(root_tree_offender "$d")" || die "cannot inspect $d (find failed)"
  [ -z "$bad" ] || die "$bad is not root-owned or is writable by group/other. Root runs this checkout's scripts and git, so the whole tree must be root-owned and not group/world writable. Fix: sudo chown -R root:root $d && sudo chmod -R go-w $d"
}
