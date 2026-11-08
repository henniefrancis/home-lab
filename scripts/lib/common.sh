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
