#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
source "$ROOT/tests/helpers.sh"
omaclone_test_env
unset NAS_BACKUP_LIB_LOADED
source "$ROOT/scripts/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

err=$(mktemp)
printf '%s\n' 'Fatal: wrong password: hunter2-LEAK-ME' >"$err"
got=$(restic_summarize_fail 1 "$err")
echo "$got" | grep -q 'hunter2-LEAK-ME' && fail "password left in fail message: $got"
[[ "$got" == "Clone failed: restic password was rejected" ]] || fail "mapped password fail: $got"

printf '%s\n' 'error: password is hunter2-LEAK-ME' >"$err"
got=$(restic_summarize_fail 1 "$err")
echo "$got" | grep -q 'hunter2-LEAK-ME' && fail "password left in 'password is' message: $got"
[[ "$got" == "Clone failed (restic exited 1)" ]] || fail "unmapped password-is fail should be generic: $got"

printf '%s\n' 'AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY boom' >"$err"
got=$(restic_summarize_fail 1 "$err")
echo "$got" | grep -q 'wJalrXUtnFEMI' && fail "aws key left in fail message: $got"
[[ "$got" == "Clone failed (restic exited 1)" ]] || fail "unknown fail should be generic: $got"

printf '%s\n' 'restic: Input/output error' >"$err"
got=$(restic_summarize_fail 1 "$err")
[[ "$got" == *"I/O error"* ]] || fail "summarize io: $got"
rm -f "$err"

write_last_result fail "$(restic_summarize_fail 1 /dev/null)"
msg=$(jq -r .message "$NAS_BACKUP_STATE_DIR/last-result.json")
[[ "$msg" == "Clone failed (restic exited 1)" ]] || fail "last-result message: $msg"

echo OK
