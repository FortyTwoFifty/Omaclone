#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$ROOT/scripts/keyring_store.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 -m py_compile "$STORE" || fail "keyring_store.py does not compile"
bash -n "$ROOT/backends/secrets/keyring" || fail "keyring backend syntax"

if grep -R --include='*.sh' --include='*.py' --include='keyring' -nE 'secret-tool[[:space:]]+store' "$ROOT" \
  | grep -v "$0" | grep -v test-keyring-store | grep -q .; then
  grep -R --include='*.sh' --include='*.py' --include='keyring' -nE 'secret-tool[[:space:]]+store' "$ROOT" || true
  fail "secret-tool store must not be used (it rewrites the default GNOME keyring)"
fi

python3 - "$STORE" <<'PY' || fail "normalize_secret unit tests"
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("keyring_store", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

assert mod.normalize_secret(b"abc") == b"abc"
assert mod.normalize_secret(b"abc\n") == b"abc"
assert mod.normalize_secret(b"abc\r\n") == b"abc"
try:
    mod.normalize_secret(b"a\nb")
except ValueError as e:
    assert "newline" in str(e)
else:
    raise SystemExit("expected newline reject")
try:
    mod.normalize_secret(b"")
except ValueError as e:
    assert "empty" in str(e)
else:
    raise SystemExit("expected empty reject")
try:
    mod.normalize_secret(b"a\0b")
except ValueError as e:
    assert "NUL" in str(e)
else:
    raise SystemExit("expected NUL reject")
print("normalize ok")
PY

if printf 'line1\nline2' | python3 "$STORE" put restic-password >/tmp/omaclone-keyring-test.err 2>&1; then
  fail "put of a multiline secret should fail before touching the keyring"
fi
grep -q newline /tmp/omaclone-keyring-test.err || fail "multiline put should mention newline"

# A fake secret-tool store must never be invoked on put.
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT
cat >"$FAKE/secret-tool" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == store ]]; then
  echo "secret-tool store was called" >&2
  exit 99
fi
exit 1
SH
chmod +x "$FAKE/secret-tool"
export PATH="$FAKE:$PATH"
export OMACLONE_KEYRING_CREATE=0
export OMACLONE_KEYRING_USE_SESSION=1

if ! python3 "$STORE" available >/dev/null 2>&1; then
  echo "SKIP: libsecret/GNOME Keyring not available for round-trip test"
  echo OK
  exit 0
fi

ATTR="test-$(date +%s)-$$"
printf '%s' "omaclone-keyring-roundtrip" | python3 "$STORE" put "$ATTR" --label "omaclone test"
got=$(python3 "$STORE" get "$ATTR")
[[ "$got" == "omaclone-keyring-roundtrip" ]] || fail "session roundtrip mismatch: $got"
python3 "$STORE" delete "$ATTR"
if python3 "$STORE" get "$ATTR" >/dev/null 2>&1; then
  fail "delete did not remove $ATTR"
fi

echo OK
