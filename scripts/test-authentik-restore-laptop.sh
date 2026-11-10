#!/usr/bin/env bash
# test-authentik-restore-laptop.sh - self-test of scripts/authentik-restore-laptop.sh (K5). No AWS: aws is a MOCK placed first on PATH
# (proved before use). Needs the real age and age-keygen, and Docker for the restore cases (a pg_dump made in a throwaway container from
# the pinned image). Cases: a good restore (PASS, users listed, container removed), a wrong key (refused before any container starts), no
# key, a corrupt dump (FAIL), stage (the section 4 rules reject a future name and an overwritten key; the upload decrypts with the Pi's
# one-off key to the exact dump), a bad Pi recipient, option misuse, and the identity never appearing in any output.
# shellcheck disable=SC2016 # the bash -c snippets are single-quoted on purpose
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
S="$PWD/scripts/authentik-restore-laptop.sh"
for t in age age-keygen docker cmp; do
  command -v "$t" > /dev/null || {
    echo "$t is required" >&2
    exit 2
  }
done
docker info > /dev/null 2>&1 || {
  echo "Docker must be running" >&2
  exit 2
}
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true

fails=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  fails=$((fails + 1))
}
check() {
  local d="$1"
  shift
  if "$@" > /dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

T="$(mktemp -d)"
MK="mkdump-$$"
# shellcheck disable=SC2317,SC2329 # run by the EXIT trap
cleanup() {
  docker rm -f "$MK" > /dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

age-keygen -o "$T/owner.key" 2> /dev/null
age-keygen -o "$T/other.key" 2> /dev/null
age-keygen -o "$T/pi.key" 2> /dev/null
OWNER_PUB="$(age-keygen -y "$T/owner.key")"
PI_PUB="$(age-keygen -y "$T/pi.key")"
SECRET="$(grep -o 'AGE-SECRET-KEY-1[0-9A-Z]*' "$T/owner.key")"

# A small dump with the tables the script inspects, made with the pinned image.
IMG="$(sed -nE 's/^[[:space:]]+image:[[:space:]]*(postgres[^[:space:]]*@sha256:[0-9a-f]{64}).*/\1/p' authentik/compose.yaml | head -n 1)"
docker run -d --rm --name "$MK" --network none -e POSTGRES_DB=authentik -e POSTGRES_USER=authentik -e POSTGRES_PASSWORD=x "$IMG" > /dev/null
for _ in $(seq 1 60); do
  docker exec "$MK" pg_isready -U authentik -d authentik > /dev/null 2>&1 && break
  sleep 2
done
docker exec "$MK" psql -U authentik -d authentik -qc "
  create table authentik_core_user(username text, type text, is_active bool, last_login timestamptz, date_joined timestamptz);
  insert into authentik_core_user values ('akadmin','internal',true,now(),now()), ('AnonymousUser','internal',true,null,now());
  create table authentik_core_application(name text); insert into authentik_core_application values ('a'), ('b');
  create table authentik_stages_authenticator_totp_totpdevice(id int); insert into authentik_stages_authenticator_totp_totpdevice values (1);
  create table authentik_stages_authenticator_webauthn_webauthndevice(id int);" > /dev/null
docker exec "$MK" pg_dump -U authentik -d authentik -Fc > "$T/plain.dump"
docker rm -f "$MK" > /dev/null 2>&1
age -r "$OWNER_PUB" -o "$T/good.dump.age" "$T/plain.dump"
printf 'PGDMPnot-a-real-dump' | age -r "$OWNER_PUB" > "$T/corrupt.dump.age"
check "fixture: the dump starts with PGDMP" bash -c '[ "$(head -c 5 "$1")" = PGDMP ]' _ "$T/plain.dump"

leftovers() { docker ps -a --filter "name=ak-restore-test-" -q | wc -l; }
before="$(leftovers)"

# --- test mode
"$S" test --dump-file "$T/good.dump.age" --key-from-stdin < "$T/owner.key" > "$T/o1" 2>&1
rc=$?
check "good dump: exit 0 and RESULT: PASS" bash -c '[ "$1" = 0 ] && grep -q "^RESULT: PASS" "$2"' _ "$rc" "$T/o1"
check "good dump: lists the users, the applications and the MFA counts" bash -c 'grep -q -- "- akadmin  (internal, active" "$1" && grep -q "applications:  2" "$1" && grep -q "TOTP devices: 1" "$1"' _ "$T/o1"
check "good dump: the throwaway container ran with --network none and is removed" bash -c 'grep -q "with no network" "$1" && [ "$(docker ps -a --filter name=ak-restore-test- -q | wc -l)" = "$2" ]' _ "$T/o1" "$before"

"$S" test --dump-file "$T/good.dump.age" --key-from-stdin < "$T/other.key" > "$T/o2" 2>&1
rc=$?
check "wrong key: exit 1, key check FAIL, no container started" bash -c '[ "$1" = 1 ] && grep -q "key check: FAIL" "$2" && ! grep -q "starting a throwaway" "$2"' _ "$rc" "$T/o2"

echo "no key here" | "$S" test --dump-file "$T/good.dump.age" --key-from-stdin > "$T/o3" 2>&1
rc=$?
check "no key: exit 2 with a clear message" bash -c '[ "$1" = 2 ] && grep -q "no AGE-SECRET-KEY-1" "$2"' _ "$rc" "$T/o3"

"$S" test --dump-file "$T/corrupt.dump.age" --key-from-stdin < "$T/owner.key" > "$T/o4" 2>&1
rc=$?
check "corrupt dump: exit 1, RESULT: FAIL, container removed" bash -c '[ "$1" = 1 ] && grep -q "^RESULT: FAIL" "$2" && [ "$(docker ps -a --filter name=ak-restore-test- -q | wc -l)" = "$3" ]' _ "$rc" "$T/o4" "$before"

printf 'not age' > "$T/plain.txt"
"$S" test --dump-file "$T/plain.txt" --key-from-stdin < "$T/owner.key" > "$T/o5" 2>&1
check "a file that is not age-encrypted is refused" grep -q "not age-encrypted" "$T/o5"

# --- stage mode with a mock aws
mkdir -p "$T/bin" "$T/s3"
cat > "$T/bin/aws" << EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/aws.log"
case "\$*" in
  *"sts get-caller-identity"*) echo '{}' ;;
  *"list-object-versions"*)
    printf '2026-11-08T20:10:01+00:00\tauthentik/20261108T200955Z.dump.age\tVID0\t3500\n'
    printf '2026-11-09T20:09:37+00:00\tauthentik/20261109T200930Z.dump.age\tVID1\t3520\n'
    printf '2026-11-09T21:00:00+00:00\tauthentik/20991231T000000Z.dump.age\tVIDF\t3500\n'
    printf '2026-11-09T23:00:00+00:00\tauthentik/20261109T225900Z.dump.age\tVIDX1\t3500\n'
    printf '2026-11-09T23:30:00+00:00\tauthentik/20261109T225900Z.dump.age\tVIDX2\t3500\n' ;;
  *"get-object"*"--version-id VID1"*) cp "$T/good.dump.age" "\${*: -1}" ;;
  *"get-object"*) echo "mock: wrong version requested" >&2; exit 9 ;;
  *"get-bucket-location"*) echo af-south-1 ;;
  *"s3 cp - s3://mock-bucket/restore/authentik-restore.dump.age"*) cat > "$T/s3/uploaded" ;;
  *"s3 presign"*) echo "https://mock.invalid/restore/authentik-restore.dump.age?X-Amz-Expires=900" ;;
  *) echo "mock aws: unexpected \$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/aws"
check "the mock aws is first on PATH" bash -c '[ "$(PATH="$1:$PATH" command -v aws)" = "$1/aws" ]' _ "$T/bin"

PATH="$T/bin:$PATH" "$S" stage --bucket mock-bucket --pi-recipient "$PI_PUB" --key-from-stdin < "$T/owner.key" > "$T/o6" 2>&1
rc=$?
check "stage: exit 0 and RESULT: PASS with a presigned URL" bash -c '[ "$1" = 0 ] && grep -q "^RESULT: PASS" "$2" && grep -q "^https://mock.invalid/" "$2"' _ "$rc" "$T/o6"
check "stage: a name in the future is rejected" grep -q "REJECTED authentik/20991231T000000Z.dump.age (VIDF): its name is in the future" "$T/o6"
check "stage: both versions of an overwritten key are rejected" bash -c 'grep -q "VIDX1): more than one version" "$1" && grep -q "VIDX2): more than one version" "$1"' _ "$T/o6"
check "stage: the newest dump that passes the rules is chosen (VID1)" grep -q "version VID1" "$T/o6"
check "stage: the upload decrypts with the Pi's one-off key to the exact dump" bash -c 'cmp <(age -d -i "$1" "$2") "$3"' _ "$T/pi.key" "$T/s3/uploaded" "$T/plain.dump"
check "stage: the presign lasts 900 seconds" grep -q -- "--expires-in 900" "$T/aws.log"

PATH="$T/bin:$PATH" "$S" stage --bucket mock-bucket --pi-recipient "$SECRET" --key-from-stdin < "$T/owner.key" > "$T/o7" 2>&1
rc=$?
check "stage: an identity passed as --pi-recipient is refused (exit 2)" bash -c '[ "$1" = 2 ] && grep -q "PUBLIC key" "$2"' _ "$rc" "$T/o7"
PATH="$T/bin:$PATH" "$S" stage --bucket mock-bucket --pi-recipient "$PI_PUB" --version-id NOPE --key-from-stdin < "$T/owner.key" > "$T/o8" 2>&1
check "an unknown --version-id is refused" grep -q "is not a dump that passes the rules" "$T/o8"
"$S" stage --dump-file "$T/good.dump.age" --pi-recipient "$PI_PUB" --key-from-stdin < "$T/owner.key" > "$T/o9" 2>&1
check "--dump-file with stage is refused" grep -q "for test only" "$T/o9"

check "the identity (its secret value) never appears in any output" bash -c 's="$1"; shift; ! grep -lF "$s" "$@"' _ "$SECRET" "$T"/o[1-9]

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; fi
[ "$fails" -eq 0 ]
