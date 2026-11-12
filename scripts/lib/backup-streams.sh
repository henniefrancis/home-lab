#!/usr/bin/env bash
# shellcheck shell=bash
# Source streams of the app backups that need real privilege handling (R19). Sourced by scripts/backup-apps.sh and by
# scripts/test-backup-sandbox.sh (the integration test that runs them as root under the unit's own sandbox properties). Needs APPS_ROOT and STAGE_BASE.
# refuse_symlink <path under APPS_ROOT>: fail closed when the path, or any part of it below APPS_ROOT, is a symlink. A compromised app owns its
# data directory and could swap a database or directory for a link; stat would then report the link's owner (the app uid) while the privileged
# read follows it to the target (QA/security N-1).
refuse_symlink() {
  local p="$1" root real
  root="$(realpath -e "$APPS_ROOT" 2> /dev/null)" || {
    echo "cannot resolve $APPS_ROOT" >&2
    return 1
  }
  real="$(realpath -e "$p" 2> /dev/null)" || {
    echo "cannot resolve $p" >&2
    return 1
  }
  if [ -L "$p" ] || [ "$real" != "$root${p#"$APPS_ROOT"}" ]; then
    echo "$p is or passes through a symbolic link (resolves to $real): refusing to back it up" >&2
    return 1
  fi
}

# sqlite_stream <directory under APPS_ROOT> <database path relative to it>: a consistent copy of a live SQLite database on stdout (R19).
# Runs in the pipeline's subshell, so its EXIT trap removes the copy on every path. Everything that touches the database runs as the owner
# of its file through setpriv, never as root: root would create root-owned -wal and -shm files and lock the app out. The private staging
# directory is created BY that uid (mode 0700) on a tmpfs, so root needs no chown and the copy never reaches the SD card.
sqlite_stream() {
  local db="$APPS_ROOT/$1/$2" owner uid gid stage size free ic
  [[ "$db" =~ ^/[A-Za-z0-9/._-]+$ ]] || {
    echo "unsafe database path" >&2
    return 1
  }
  [[ "$STAGE_BASE" =~ ^/[A-Za-z0-9/._-]+$ ]] || {
    echo "unsafe staging directory $STAGE_BASE" >&2
    return 1
  }
  command -v sqlite3 > /dev/null 2>&1 || {
    echo "sqlite3 is not installed (sudo scripts/bootstrap.sh)" >&2
    return 1
  }
  command -v setpriv > /dev/null 2>&1 || {
    echo "setpriv is not installed (util-linux)" >&2
    return 1
  }
  refuse_symlink "$db" || return 1
  owner="$(stat -c '%u:%g' "$db")" || return 1
  uid="${owner%%:*}"
  gid="${owner##*:}"
  [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$gid" =~ ^[0-9]+$ ]] && [ "$uid" -ne 0 ] || {
    echo "$db is owned by $owner: refusing to run sqlite3 as root next to a live database" >&2
    return 1
  }
  [ "$(stat -f -c %T "$STAGE_BASE" 2> /dev/null || true)" = tmpfs ] || {
    echo "$STAGE_BASE is not a tmpfs: refusing to write a plaintext database copy to disk" >&2
    return 1
  }
  # The copy must fit the staging tmpfs with room to spare: the database plus its WAL must be smaller than half of the tmpfs's free space
  # (the tmpfs is RAM, so this also bounds the memory used). It is measured with stat, not from the kernel memory statistics: the unit hides those (ProcSubset=pid).
  size="$(($(stat -c %s "$db") + $(stat -c %s "$db-wal" 2> /dev/null || echo 0)))"
  free="${HOME_LAB_STAGE_FREE_BYTES:-$(($(stat -f -c '%a' "$STAGE_BASE") * $(stat -f -c '%S' "$STAGE_BASE")))}"
  [[ "$size" =~ ^[0-9]+$ ]] && [[ "$free" =~ ^[0-9]+$ ]] && [ "$size" -lt $((free / 2)) ] || {
    echo "the database ($size bytes with its WAL) is not smaller than half of the free space of $STAGE_BASE ($free bytes)" >&2
    return 1
  }
  as_app() { setpriv --reuid="$uid" --regid="$gid" --clear-groups "$@"; }
  # /apps is 0700 root, so the app uid cannot even reach its own database. Only sqlite3 gets CAP_DAC_READ_SEARCH (search on directories),
  # as an ambient capability of that one child; the uid stays the app's, and writing still follows the file's own owner. The capability is
  # in the unit's bounding set (the unit already has it for the tar jobs).
  as_app_db() { setpriv --reuid="$uid" --regid="$gid" --clear-groups --inh-caps=+dac_read_search --ambient-caps=+dac_read_search "$@"; }
  stage="$(as_app mktemp -d "$STAGE_BASE/home-lab-backup.XXXXXX")" || {
    echo "cannot create a staging directory in $STAGE_BASE as uid $uid" >&2
    return 1
  }
  # shellcheck disable=SC2064 # expanded now, on purpose: the function's locals are gone when the trap fires
  trap "setpriv --reuid=$uid --regid=$gid --clear-groups rm -rf '$stage'" EXIT
  as_app_db sqlite3 -init /dev/null -cmd '.timeout 10000' "$db" ".backup '$stage/copy.db'" || {
    echo "sqlite3 .backup failed" >&2
    return 1
  }
  ic="$(as_app sqlite3 -init /dev/null "$stage/copy.db" 'PRAGMA integrity_check;' 2>&1 | head -n 1)" || true
  [ "$ic" = ok ] || {
    echo "integrity_check on the copy failed: ${ic:0:120}" >&2
    return 1
  }
  as_app cat "$stage/copy.db"
}

# couch_stream <directory under APPS_ROOT>: tar in the order the CouchDB documentation requires for a live copy: the .shards directory
# first, then shards, then the top-level *.couch files (_dbs, _nodes), then etc (runtime configuration and the hashed admin password).
# The files are append-only; tar's exit 1 ("file changed as we read it") is therefore tolerated, anything above 1 is a failure.
couch_stream() {
  local base="$APPS_ROOT/$1" p rc=0
  refuse_symlink "$base/data" || return 1
  local paths=()
  for p in data/.shards data/shards; do [ -d "$base/$p" ] && paths+=("$p"); done
  for p in "$base"/data/*.couch; do [ -f "$p" ] && paths+=("data/$(basename "$p")"); done
  [ -d "$base/etc" ] && paths+=(etc)
  [ "${#paths[@]}" -gt 0 ] || {
    echo "nothing to archive below $base" >&2
    return 1
  }
  tar -C "$base" -cf - "${paths[@]}" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
}

