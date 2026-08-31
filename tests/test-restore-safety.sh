#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env
fail() { echo "FAIL: $*" >&2; exit 1; }

"$ROOT/scripts/omaclone" -h | grep -q -- '--blank-omarchy' || fail "usage missing --blank-omarchy"
"$ROOT/scripts/omaclone" -h | grep -q -- '--delete' || fail "usage missing --delete"

dest=$(mktemp -d)
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
[[ -f "$dest/SHA256SUMS" ]] || fail "bootstrap SHA256SUMS missing"

# Tampered kit must refuse to exec without UNTRUSTED (no plugin under temp HOME).
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000  scripts/omaclone" >"$dest/SHA256SUMS"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "tampered kit restore should fail: $out"
printf '%s\n' "$out" | grep -qi "SHA256SUMS\|UNTRUSTED\|changed" \
  || fail "tampered kit should mention hash: $out"

# Good hashes: launcher should get past the hash check (it may fail later on setup).
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | grep -qi "SHA256SUMS\|UNTRUSTED" && fail "good kit should not warn about hash: $out"

rm -rf "$dest"
echo OK
