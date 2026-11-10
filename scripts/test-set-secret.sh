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
    if [ "${MOCK_TYPE:-SecureString}" = MISSING ]; then echo "An error occurred (ParameterNotFound)" >&2; exit 254; fi
    echo "${MOCK_TYPE:-SecureString}"; exit 0 ;;
  *" ssm describe-parameters "*)
    printf '%s' "${MOCK_PARAMS:-[]}"; exit 0 ;;
  *" ssm put-parameter "*)
    if [ -n "${MOCK_EXISTS:-}" ]; then echo "An error occurred (ParameterAlreadyExists)" >&2; exit 254; fi
    src=""
    for i in "${!args[@]}"; do
      if [ "${args[$i]}" = "--cli-input-json" ]; then src="${args[$((i + 1))]#file://}"; fi
    done
    if [ "$src" = /dev/stdin ]; then cat > "$out/req.json"; else cat "$src" > "$out/req.json"; fi
    jq -c . < "$out/req.json" >> "$out/reqs.log" # stdin: jq.exe under Git Bash gets no path conversion here
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
  rm -f "$MOCK_OUT/req.json" "$MOCK_OUT/reqs.log"
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
run '' --create tailscale/auth-key
check "--create writes the placeholder, Overwrite false, SecureString, key alias, tags Project and ManagedBy (no prompt)" bash -c 'jq -e "(.Value | startswith(\"UNSET-\")) and .Overwrite == false and .Type == \"SecureString\" and .KeyId == \"alias/home-lab-ssm\" and .Tier == \"Standard\" and ([.Tags[] | .Key + \"=\" + .Value] | sort == [\"ManagedBy=set-secret.sh\",\"Project=home-lab\"])" "$1"' _ "$MOCK_OUT/req.json"
MOCK_EXISTS=1 run '' --create tailscale/auth-key
check "--create on an existing parameter fails (never overwrites)" test "$rc" -ne 0
run '' --create not-in/manifest
check "--create refuses a name that is not a SecureString row of the manifest (exit 2, nothing sent)" bash -c 'test "$1" -eq 2 && test ! -f "$2/req.json"' _ "$rc" "$MOCK_OUT"
run 'x\nx\n' tailscale/auth-key
check "a normal set never sends Tags (they are only valid with Overwrite false)" bash -c '! jq -e "has(\"Tags\")" "$1"' _ "$MOCK_OUT/req.json"

# --generate (machine-only secrets): random, never shown, never overwrites
MOCK_TYPE=MISSING run '' --generate authentik/secret-key pihole/admin-password
check "--generate creates every named secret (exit 0, one write each)" bash -c 'test "$1" -eq 0 && test "$(wc -l < "$2/reqs.log")" -eq 2' _ "$rc" "$MOCK_OUT"
check "--generate: each value is 64 hex characters, and the two differ" bash -c 'v="$(jq -r .Value "$1/reqs.log")"; [ "$(grep -cE "^[0-9a-f]{64}$" <<< "$v")" = 2 ] && [ "$(sort -u <<< "$v" | wc -l)" = 2 ]' _ "$MOCK_OUT"
check "--generate writes SecureString, Overwrite false, the key alias and the tags" bash -c 'jq -se "all(.[]; .Type == \"SecureString\" and .Overwrite == false and .KeyId == \"alias/home-lab-ssm\" and ([.Tags[] | .Key] | sort == [\"ManagedBy\",\"Project\"]))" "$1/reqs.log"' _ "$MOCK_OUT"
check "--generate never shows a value (not in the output, not in any command line)" bash -c 'for v in $(jq -r .Value "$1/reqs.log"); do grep -qF "$v" "$2" "$1/calls.log" && exit 1; done; exit 0' _ "$MOCK_OUT" "$work/o"
check "--generate names each parameter and says the value was not shown" bash -c 'grep -q "Generated /home-lab/authentik/secret-key" "$1" && grep -q "value never shown" "$1"' _ "$work/o"
run '' --generate authentik/secret-key
check "--generate refuses an existing parameter (exit 1, nothing written: a value may be in use)" bash -c 'test "$1" -eq 1 && test ! -f "$2/reqs.log" && grep -q "already exists" "$3"' _ "$rc" "$MOCK_OUT" "$work/o"
MOCK_TYPE=MISSING run '' --generate not-in/manifest
check "--generate refuses a name that is not in the manifest (exit 2, nothing sent)" bash -c 'test "$1" -eq 2 && test ! -f "$2/reqs.log"' _ "$rc" "$MOCK_OUT"
MOCK_TYPE=MISSING run '' --generate config/domain
check "--generate refuses config/* (Terraform owns it)" bash -c 'test "$1" -eq 2 && test ! -f "$2/reqs.log"' _ "$rc" "$MOCK_OUT"
run '' --generate
check "--generate with no name is a usage error (exit 2)" test "$rc" -eq 2

good='[{"n":"/home-lab/authentik/secret-key","t":"SecureString","k":"alias/home-lab-ssm","v":3},{"n":"/home-lab/authentik/postgres-password","t":"SecureString","k":"alias/home-lab-ssm","v":2},{"n":"/home-lab/authentik/bootstrap-password","t":"SecureString","k":"alias/home-lab-ssm","v":2},{"n":"/home-lab/traefik/breakglass-htpasswd","t":"SecureString","k":"alias/home-lab-ssm","v":2},{"n":"/home-lab/tailscale/auth-key","t":"SecureString","k":"alias/home-lab-ssm","v":4},{"n":"/home-lab/homepage/authentik-token","t":"SecureString","k":"alias/home-lab-ssm","v":2},{"n":"/home-lab/pihole/admin-password","t":"SecureString","k":"alias/home-lab-ssm","v":1},{"n":"/home-lab/config/domain","t":"String","k":null,"v":1}]'
MOCK_PARAMS="$good" run '' --check
check "--check passes when all seven SecureStrings exist on alias/home-lab-ssm (config/* is not required to be a SecureString)" bash -c 'test "$1" -eq 0 && grep -q "check OK" "$2" && grep -q "authentik/secret-key" "$2"' _ "$rc" "$work/o"
check "--check prints key and version only: no value, nothing was written" bash -c '! grep -qi "value" "$1" && test ! -f "$2/req.json"' _ "$work/o" "$MOCK_OUT"
bad_missing="$(jq -c 'map(select(.n != "/home-lab/tailscale/auth-key"))' <<< "$good")"
MOCK_PARAMS="$bad_missing" run '' --check
check "--check fails (exit 1) when one SecureString is missing, and names it" bash -c 'test "$1" -eq 1 && grep -q "tailscale/auth-key.*MISSING" "$2"' _ "$rc" "$work/o"
bad_key="$(jq -c 'map(if .n == "/home-lab/authentik/secret-key" then .k = "alias/aws/ssm" else . end)' <<< "$good")"
MOCK_PARAMS="$bad_key" run '' --check
check "--check fails (exit 1) when a SecureString is not on the home-lab key" bash -c 'test "$1" -eq 1 && grep -q "NOT on alias/home-lab-ssm" "$2"' _ "$rc" "$work/o"
bad_type="$(jq -c 'map(if .n == "/home-lab/authentik/secret-key" then .t = "String" else . end)' <<< "$good")"
MOCK_PARAMS="$bad_type" run '' --check
check "--check fails when a parameter is a plain String" bash -c 'test "$1" -eq 1 && grep -q "NOT a SecureString" "$2"' _ "$rc" "$work/o"
run 'x\n' --check authentik/secret-key
check "--check takes no name (exit 2)" test "$rc" -eq 2
check "the expected list is the manifest: seven SecureStrings" test "$(grep -vE '^(#|$)' config/secrets-manifest.tsv | cut -f1 | grep -vc '^config/')" -eq 7

# NEW-10: --check and --create must not pass vacuously on an unreadable, empty or comment-only manifest, and must survive a huge one
printf '# only comments\n\n' > "$work/comments.tsv"
: > "$work/empty.tsv"
for m in "$work/does-not-exist.tsv" "$work/empty.tsv" "$work/comments.tsv"; do
  SECRETS_MANIFEST="$m" MOCK_PARAMS="$good" run '' --check
  check "--check with manifest '$(basename "$m")' fails with exit 2 and never prints 'check OK' (NEW-10)" bash -c 'test "$1" -eq 2 && ! grep -q "check OK" "$2" && grep -q "Cannot read any SecureString row" "$2"' _ "$rc" "$work/o"
  rm -f "$MOCK_OUT/req.json"
  SECRETS_MANIFEST="$m" run '' --create tailscale/auth-key
  check "--create with manifest '$(basename "$m")' fails with exit 2 and sends nothing (NEW-10)" bash -c 'test "$1" -eq 2 && test ! -f "$2/req.json"' _ "$rc" "$MOCK_OUT"
done
MOCK_PARAMS=null run '' --check
check "--check with a describe-parameters answer of null exits 1 with a message, not a jq error (NEW-10)" bash -c 'test "$1" -eq 1 && grep -q "not a JSON list" "$2" && ! grep -qi "jq:" "$2"' _ "$rc" "$work/o"
{ printf 'tailscale/auth-key\ttailscale/tailscale.env\t0:0\t0600\tyes\traw\n'; seq 1 200000 | awk '{printf "svc%d/name-%d\tx\t0:0\t0600\tyes\traw\n", $1, $1}'; } > "$work/huge.tsv"
for _ in 1 2 3; do
  SECRETS_MANIFEST="$work/huge.tsv" run '' --create tailscale/auth-key
  [ "$rc" -eq 0 ] || break
done
check "--create finds a name in a 200000-row manifest three times in a row (no SIGPIPE under pipefail, NEW-10)" test "$rc" -eq 0

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
