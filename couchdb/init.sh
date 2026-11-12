#!/bin/sh
# couchdb-init (R19, M16): idempotent one-shot that prepares the LiveSync sync user and database, then exits 0.
# Talks only to http://couchdb:5984 as the server admin (password from the secret file). Creates (or fixes) the user
# COUCHDB_SYNC_USER with the password from couchdb/sync-password, creates the database COUCHDB_SYNC_DB and sets its _security so the sync user
# is admin AND member of that ONE database (the plugin writes design documents) and has no server-admin rights. Secrets never appear in argv:
# curl reads its credentials from a config on stdin.
set -eu
BASE=http://couchdb:5984
USER_NAME="${COUCHDB_SYNC_USER:?}"
DB="${COUCHDB_SYNC_DB:?}"
case "$USER_NAME" in [a-z]*) ;; *) echo "bad COUCHDB_SYNC_USER" >&2; exit 1 ;; esac
case "$USER_NAME$DB" in *[!a-z0-9_-]*) echo "COUCHDB_SYNC_USER and COUCHDB_SYNC_DB: lower-case letters, digits, _ and - only" >&2; exit 1 ;; esac
case "$DB" in [a-z]*) ;; *) echo "bad COUCHDB_SYNC_DB" >&2; exit 1 ;; esac
ADMIN_PW="$(cat /run/secrets/couchdb_admin_password)"
SYNC_PW="$(cat /run/secrets/couchdb_sync_password)"
# control characters would break the JSON body; refuse them (a quote or backslash is escaped below)
if printf '%s' "$SYNC_PW" | LC_ALL=C grep -q '[[:cntrl:]]'; then echo "the sync password holds a control character" >&2; exit 1; fi
[ -n "$SYNC_PW" ] || { echo "the sync password is empty" >&2; exit 1; }
# The JSON bodies that hold a password go through a 0600 file on the /tmp tmpfs (--data-binary @file), never through curl's argv.
umask 077
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
# api <user> <password> <curl args...>: prints the body, then the HTTP code on a last line
api() {
  u="$1"
  p="$2"
  shift 2
  printf 'user = "%s:%s"\n' "$u" "$(esc "$p")" | curl -sS -K - -w '\n%{http_code}' "$@"
}
code_of() { tail -n 1; }
body_of() { sed '$d'; }
for _ in $(seq 1 30); do
  r="$(api admin "$ADMIN_PW" "$BASE/_up" 2> /dev/null | code_of || true)"
  [ "$r" = 200 ] && break
  sleep 2
done
[ "$r" = 200 ] || { echo "CouchDB did not answer as admin" >&2; exit 1; }
# system databases (single_node creates them; this is a no-op then)
for d in _users _replicator; do
  c="$(api admin "$ADMIN_PW" -X PUT "$BASE/$d" | code_of)"
  case "$c" in 201 | 202 | 412) ;; *) echo "creating $d failed: HTTP $c" >&2; exit 1 ;; esac
done
# the sync user: skip when it already authenticates with the current password
s="$(api "$USER_NAME" "$SYNC_PW" "$BASE/_session" | body_of)"
if printf '%s' "$s" | grep -q "\"name\":\"$USER_NAME\""; then
  echo "sync user $USER_NAME already set"
else
  url="$BASE/_users/org.couchdb.user:$USER_NAME"
  cur="$(api admin "$ADMIN_PW" "$url")"
  rev=""
  if [ "$(printf '%s\n' "$cur" | code_of)" = 200 ]; then
    rev="$(printf '%s\n' "$cur" | body_of | sed -n 's/.*"_rev":"\([^"]*\)".*/\1/p')"
  fi
  doc="{\"name\":\"$USER_NAME\",\"password\":\"$(esc "$SYNC_PW")\",\"roles\":[],\"type\":\"user\""
  [ -z "$rev" ] || doc="$doc,\"_rev\":\"$rev\""
  printf "%s}" "$doc" > "$BODY"
  c="$(api admin "$ADMIN_PW" -X PUT -H 'Content-Type: application/json' --data-binary "@$BODY" "$url" | code_of)"
  case "$c" in 201 | 202) echo "sync user $USER_NAME written" ;; *) echo "writing the sync user failed: HTTP $c" >&2; exit 1 ;; esac
fi
c="$(api admin "$ADMIN_PW" -X PUT "$BASE/$DB" | code_of)"
case "$c" in 201 | 202 | 412) ;; *) echo "creating database $DB failed: HTTP $c" >&2; exit 1 ;; esac
sec="{\"admins\":{\"names\":[\"$USER_NAME\"],\"roles\":[]},\"members\":{\"names\":[\"$USER_NAME\"],\"roles\":[]}}"
c="$(api admin "$ADMIN_PW" -X PUT -H 'Content-Type: application/json' --data-binary "$sec" "$BASE/$DB/_security" | code_of)"
case "$c" in 200 | 201 | 202) echo "database $DB ready" ;; *) echo "setting _security on $DB failed: HTTP $c" >&2; exit 1 ;; esac
