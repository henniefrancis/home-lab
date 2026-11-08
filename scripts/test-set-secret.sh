#!/usr/bin/env bash
# test-set-secret.sh - offline self-test of scripts/set-secret.sh against a MOCK aws (QA-L-7, QA-L-8, SEC-M2, SEC-L7).
# Needs jq. Never contacts AWS: the mock is placed first on PATH, the AWS config and credentials are disabled, and the test
# PROVES the mock is the aws that will run (marker call) before any case runs; it aborts otherwise.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose: $1, $2 expand in the child shell
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
command -v jq > /dev/null || {
  echo "jq is required" >&2
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/out"

# --- the mock ------------------------------------------------------------------------------------------------------
cat > "$work/bin/aws" << 'MOCK'
#!/usr/bin/env bash
# MOCK aws for test-set-secret.sh. Records the request; prints fixed answers.
out="${MOCK_OUT:?}"
args=("$@")
printf '%s\n' "${args[*]}" >> "$out/calls.log"
case " ${args[*]} " in
  *" sts get-caller-identity "*)
    if [ "${MOCK_AUTH:-ok}" = ok ]; then echo "MOCK-ACCOUNT"; exit 0; else exit 255; fi ;;
  *" ssm get-parameter "*)
    echo "${MOCK_TYPE:-SecureString}"; exit 0 ;;
  *" ssm put-parameter "*)
    src=""
    for i in "${!args[@]}"; do
      if [ "${args[$i]}" = "--cli-input-json" ]; then src="${args[$((i + 1))]#file://}"; fi
    done
    if [ "$src" = /dev/stdin ]; then cat > "$out/req.json"; else cat "$src" > "$out/req.json"; fi
    echo 7 ;;
  *" --mock-marker "*) echo "MOCK-AWS-MARKER" ;;
  *) echo "mock: unexpected call: ${args[*]}" >&2; exit 99 ;;
esac
MOCK
chmod +x "$work/bin/aws"

export MOCK_OUT="$work/out"
export PATH="$work/bin:$PATH"
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PROFILE=does-not-exist
export AWS_EC2_METADATA_DISABLED=true AWS_PROFILE_NAME=mock-profile

# PROOF that the mock, not a real CLI, will run.
case "$(command -v aws)" in
  "$work"/bin/aws) ;;
  *)
    echo "ABORT: aws on PATH is not the mock" >&2
    exit 3
    ;;
esac
[ "$(aws --mock-marker)" = "MOCK-AWS-MARKER" ] || {
  echo "ABORT: the mock marker call did not answer" >&2
  exit 3
}
rm -f "$MOCK_OUT/calls.log"

run() { # run <stdin text> <args...>; prints the exit code in $rc, output in $work/o
  local input="$1"
  shift
  rm -f "$MOCK_OUT/req.json"
  set +e
  printf '%b' "$input" | bash scripts/set-secret.sh "$@" > "$work/o" 2>&1
  rc=$?
  set -e
}

run 'abc-secret\nabc-secret\n' authentik/secret-key
check "a normal set succeeds (exit 0)" test "$rc" -eq 0
check "request carries the value, SecureString, Overwrite true" bash -c 'jq -e ".Value == \"abc-secret\" and .Type == \"SecureString\" and .Overwrite == true and .Name == \"/home-lab/authentik/secret-key\"" "$1"' _ "$MOCK_OUT/req.json"
check "request carries the customer-managed key alias by default (SEC-M2)" bash -c 'jq -e ".KeyId == \"alias/home-lab-ssm\"" "$1"' _ "$MOCK_OUT/req.json"
check "the value never appears in the command line or output" bash -c '! grep -rq "abc-secret" "$1/calls.log" "$2"' _ "$MOCK_OUT" "$work/o"

SSM_KEY_ALIAS=alias/other-key run 'x1\nx1\n' tailscale/auth-key
check "SSM_KEY_ALIAS overrides the key" bash -c 'jq -e ".KeyId == \"alias/other-key\"" "$1"' _ "$MOCK_OUT/req.json"
SSM_KEY_ALIAS='not-an-alias' run 'x1\nx1\n' tailscale/auth-key
check "a malformed key alias is refused (exit 2), nothing sent" bash -c 'test "$1" -eq 2 && test ! -f "$2/req.json"' _ "$rc" "$MOCK_OUT"

run 'abc\r\nabc\r\n' authentik/secret-key
check "a trailing carriage return is stripped (QA-L-7)" bash -c 'jq -e ".Value == \"abc\"" "$1"' _ "$MOCK_OUT/req.json"

long="$(head -c 5000 /dev/zero | tr '\0' 'a')"
run "${long}\n${long}\n" authentik/secret-key
check "a value over 4096 characters is refused before any AWS write (QA-L-7)" bash -c 'test "$1" -eq 1 && test ! -f "$2/req.json" && grep -q "4096" "$3"' _ "$rc" "$MOCK_OUT" "$work/o"
ok4096="$(head -c 4096 /dev/zero | tr '\0' 'b')"
run "${ok4096}\n${ok4096}\n" authentik/secret-key
check "exactly 4096 characters is accepted" bash -c 'test "$1" -eq 0 && jq -e ".Value | length == 4096" "$2"' _ "$rc" "$MOCK_OUT/req.json"

run '' authentik/secret-key
check "EOF at the first prompt gives a message and exit 1 (QA-L-7)" bash -c 'test "$1" -eq 1 && grep -qi "end of file" "$2"' _ "$rc" "$work/o"
run 'only-once\n' authentik/secret-key
check "EOF at the second prompt gives a message and exit 1" bash -c 'test "$1" -eq 1 && grep -qi "end of file" "$2" && test ! -f "$3/req.json"' _ "$rc" "$work/o" "$MOCK_OUT"
run 'aaa\nbbb\n' authentik/secret-key
check "mismatching values write nothing" bash -c 'test "$1" -eq 1 && test ! -f "$2/req.json"' _ "$rc" "$MOCK_OUT"
run '\n\n' authentik/secret-key
check "an empty value is refused" bash -c 'test "$1" -eq 1 && test ! -f "$2/req.json"' _ "$rc" "$MOCK_OUT"
run 'UNSET-fake\nUNSET-fake\n' authentik/secret-key
check "a value that looks like the placeholder is refused" bash -c 'test "$1" -eq 1 && test ! -f "$2/req.json"' _ "$rc" "$MOCK_OUT"

run '' --unset tailscale/auth-key
check "--unset writes the placeholder with the key id" bash -c 'test "$1" -eq 0 && jq -e ".Value | startswith(\"UNSET-\")" "$2" && jq -e ".KeyId == \"alias/home-lab-ssm\"" "$2"' _ "$rc" "$MOCK_OUT/req.json"
run 'abc\nabc\n' --create authentik/secret-key
check "--create sets Overwrite false" bash -c 'jq -e ".Overwrite == false" "$1"' _ "$MOCK_OUT/req.json"

run 'abc\nabc\n' config/domain
check "config/* is refused (exit 2)" test "$rc" -eq 2
run 'abc\nabc\n' 'Bad Name'
check "a malformed name is refused (exit 2)" test "$rc" -eq 2
MOCK_AUTH=fail run 'abc\nabc\n' authentik/secret-key
check "not authenticated: exit 1 and a login hint" bash -c 'test "$1" -eq 1 && grep -q "aws sso login" "$2"' _ "$rc" "$work/o"
MOCK_TYPE=String run 'abc\nabc\n' authentik/secret-key
check "a parameter that is not a SecureString is refused" bash -c 'test "$1" -eq 1 && test ! -f "$2/req.json"' _ "$rc" "$MOCK_OUT"

check "no temp request file is left behind (cleanup ran)" bash -c '! ls "${TMPDIR:-/tmp}"/tmp.*/req.json 2>/dev/null | grep -q .'
check "trap structure: INT and TERM exit, cleanup on EXIT only (QA-L-8)" bash -c "grep -q \"^trap 'exit 130' INT\" scripts/set-secret.sh && grep -q \"^trap 'exit 143' TERM\" scripts/set-secret.sh && grep -q '^trap cleanup EXIT\$' scripts/set-secret.sh"

if [ "$fails" -gt 0 ]; then
  printf '\n%s check(s) FAILED\n' "$fails"
  exit 1
fi
printf '\nAll set-secret checks passed\n'
