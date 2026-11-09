#!/usr/bin/env bash
# test-gitleaks-rules.sh - checks the custom rules of .gitleaks.toml (N12) and scripts/check-private-denylist.sh with the pinned gitleaks
# image. Needs docker. Everything is synthetic: temp directories, fabricated identifiers, nothing real, no network except the image pull.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose: $1, $2 expand in the child shell
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"
command -v docker > /dev/null || {
  echo "docker is required" >&2
  exit 2
}
native_path() { if command -v cygpath > /dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
IMG="$(awk '$1=="FROM" && $4=="gitleaks" {print $2}' ci/images/gitleaks/Dockerfile)"
[ -n "$IMG" ] || {
  echo "no gitleaks image pinned" >&2
  exit 2
}

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

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/pub" "$T/priv-repo"
cp .gitleaks.toml "$T/gitleaks.toml"

finds() { ! scan_dir "$1" > /dev/null 2>&1; } # true when the scan reports a finding (or fails)
# scan_dir <dir>: gitleaks dir with the PUBLIC config; exit code 1 = a finding
scan_dir() {
  MSYS_NO_PATHCONV=1 docker run --rm -v "$(native_path "$1"):/scan:ro" -v "$(native_path "$T"):/cfg:ro" "$IMG" dir /scan --config /cfg/gitleaks.toml --redact --no-banner
}

# ---------------------------------------------------------------- public rules: identifiers are caught
printf 'account = "384756291034"\n' > "$T/pub/acct.txt"
check "a fabricated 12-digit account ID is a finding" finds "$T/pub"
rm -f "$T/pub/acct.txt"
printf 'arn:aws:iam::384756291034:role/x\n' > "$T/pub/arn.txt"
check "an account ID inside an ARN is a finding" finds "$T/pub"
rm -f "$T/pub/arn.txt"
printf 'zone = "Z3ABCDEF123456789ABC"\n' > "$T/pub/zone.txt"
check "a fabricated hosted zone ID is a finding" finds "$T/pub"
rm -f "$T/pub/zone.txt"

# ---------------------------------------------------------------- public rules: the documented placeholders and look-alikes are not
cat > "$T/pub/placeholders.txt" << 'EOF'
111111111111
123456789012
000000000000
arn:aws:iam::111111111111:role/example
key_id = "00000000-0000-0000-0000-000000000002"
big = 1234567890123
zone = "Z0000000000000000000"
zone = "Z1AAAAAAAAAAAAAAAAAA"
zone = "Z2BBBBBBBBBBBBBBBBBB"
word = ZENDESK
EOF
check "the placeholders, a UUID segment, a 13-digit number and plain words are NOT findings" scan_dir "$T/pub"

# ---------------------------------------------------------------- the repository itself is clean under the public rules (history and tree)
mkdir -p "$T/tree"
git archive HEAD | tar -x -C "$T/tree"
check "the committed tree has no finding under the public rules (git archive HEAD)" scan_dir "$T/tree"

# ---------------------------------------------------------------- check-private-denylist.sh
# a throwaway git repository with one commit that contains a (fabricated) private value
git -C "$T/priv-repo" init -q -b main
mkdir -p "$T/priv-repo/ci/images/gitleaks" "$T/priv-repo/scripts"
cp ci/images/gitleaks/Dockerfile "$T/priv-repo/ci/images/gitleaks/Dockerfile"
printf 'host = "lab.secret-example.invalid"\n' > "$T/priv-repo/notes.txt"
git -C "$T/priv-repo" add -A
git -C "$T/priv-repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m "synthetic"
cat > "$T/private.toml" << 'EOF'
title = "test denylist"
[[rules]]
id = "private-domain"
description = "synthetic"
regex = '''(?i)lab\.secret-example\.invalid'''
EOF
cp "$T/private.toml" "$T/clean.toml"
sed -i 's/secret-example/other-value/' "$T/clean.toml"
rc=0
bash scripts/check-private-denylist.sh --repo "$T/priv-repo" --config "$T/private.toml" > "$T/o" 2>&1 || rc=$?
check "the private denylist finds a private value in the history (exit 1)" test "$rc" -eq 1
rc=0
bash scripts/check-private-denylist.sh --repo "$T/priv-repo" --config "$T/clean.toml" > "$T/o" 2>&1 || rc=$?
check "a denylist that matches nothing passes (exit 0)" test "$rc" -eq 0
rc=0
bash scripts/check-private-denylist.sh --repo "$T/priv-repo" --config "$T/missing.toml" > "$T/o" 2>&1 || rc=$?
check "a missing private file is 'not configured' (exit 2), never a silent pass" bash -c 'test "$1" -eq 2 && grep -q "No private denylist" "$2"' _ "$rc" "$T/o"
rc=0
bash scripts/check-private-denylist.sh --repo "$T/priv-repo" --config "$REPO/.gitleaks-private.toml.example" > "$T/o" 2>&1 || rc=$?
check "the untouched template is refused (exit 2)" bash -c 'test "$1" -eq 2 && grep -q "FILL-IN-BEFORE-USE" "$2"' _ "$rc" "$T/o"
check "the real private file name is gitignored" bash -c 'git -C "$1" check-ignore -q .gitleaks-private.toml' _ "$REPO"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll gitleaks rule checks passed\n'
