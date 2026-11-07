#!/usr/bin/env bash
# Self-test for the existing_records generator (scripts/inventory.jq): fixture JSON in, expected HCL out.
# Runs locally or in CI with no AWS access. To regenerate the expectation after an intended change:
#   jq -r --arg apex "example.com." -f scripts/inventory.jq scripts/testdata/records.json > scripts/testdata/expected.hcl
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
actual="$(jq -r --arg apex "example.com." -f "$dir/inventory.jq" "$dir/testdata/records.json" | tr -d '\r')"
expected="$(tr -d '\r' < "$dir/testdata/expected.hcl")"
fail=0
if [ "$actual" != "$expected" ]; then
  echo "FAIL: generated HCL differs from testdata/expected.hcl"
  diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
  fail=1
fi
# Invariants that matter for adoption: no wire quotes at the start or end of any TXT value, no CR, no empty list entries.
if printf '%s\n' "$actual" | grep -E 'records = \["\\"' > /dev/null; then echo "FAIL: TXT value still has wire quotes"; fail=1; fi
if printf '%s\n' "$actual" | grep -q "$(printf '\r')"; then echo "FAIL: carriage return in output"; fail=1; fi
if printf '%s\n' "$actual" | grep -E '(^|[^a-z])(NS|SOA)"$' > /dev/null && printf '%s\n' "$actual" | grep -q 'type = "SOA"'; then echo "FAIL: apex SOA leaked"; fail=1; fi
[ "$fail" = 0 ] && echo "inventory self-test OK"
exit "$fail"
