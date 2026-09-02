#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$ROOT/config/omaclone-kit.pub" ]] || fail "missing config/omaclone-kit.pub"
[[ -f "$ROOT/config/omaclone-kit.sig" ]] || fail "missing config/omaclone-kit.sig"
grep -q 'MCowBQYDK2VwAyEAxmJomSkS0fDbZLxJA6YNjedgar61rjmWrZJJD3icr0k=' "$ROOT/scripts/restore" \
  || fail "restore must embed the project public key"
grep -q 'MCowBQYDK2VwAyEAxmJomSkS0fDbZLxJA6YNjedgar61rjmWrZJJD3icr0k=' "$ROOT/scripts/kit_auth.py" \
  || fail "kit_auth must embed the project public key"
python3 "$ROOT/scripts/kit_auth.py" --verify "$ROOT" \
  || fail "committed tree signature must verify"

digest=$(python3 "$ROOT/scripts/kit_auth.py" --digest "$ROOT")
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "digest should be sha256 hex"

# Signature is over the digest; SHA256SUMS is not authentication.
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env
dest=$(mktemp -d)
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
[[ -f "$dest/omaclone/config/omaclone-kit.sig" ]] || fail "kit missing copied signature"
python3 "$ROOT/scripts/kit_auth.py" --verify "$dest/omaclone" \
  || fail "copied kit signature must verify"

# Tamper a hashed file; signature must fail closed (no UNTRUSTED prompt).
printf '\n# pwned\n' >>"$dest/omaclone/scripts/omaclone"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "tampered kit restore should fail: $out"
printf '%s\n' "$out" | grep -qi "signature\|unsigned\|changed" \
  || fail "tampered kit should mention signature: $out"
printf '%s\n' "$out" | grep -qi 'Type UNTRUSTED' && fail "must fail closed, not UNTRUSTED"

# Good kit: no signature warning.
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
set -e
printf '%s\n' "$out" | grep -qi "signature\|UNTRUSTED" && fail "good kit should not warn: $out"

# Missing signature fails closed.
rm -f "$dest/omaclone/config/omaclone-kit.sig"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "unsigned kit should fail: $out"

rm -rf "$dest"
echo OK
