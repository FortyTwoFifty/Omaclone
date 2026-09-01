#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$ROOT/scripts/keyring_store.py"

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 -m py_compile "$STORE" || fail "keyring_store.py does not compile"
bash -n "$ROOT/backends/secrets/keyring" || fail "keyring backend syntax"
bash -n "$ROOT/backends/secrets/pass-cli" || fail "pass-cli backend syntax"
bash -n "$ROOT/backends/secrets/1password" || fail "1password backend syntax"

hits=$(grep -R --include='*.sh' --include='*.py' --include='keyring' --include='pass-cli' --include='1password' \
  -nE 'secret-tool[[:space:]]+(store|clear|delete)|Secret\.Service\.store_sync|password_store_sync|password_store\(' \
  "$ROOT" | grep -v "$0" | grep -v test-keyring-store | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [[ -n "$hits" ]]; then
  printf '%s\n' "$hits"
  fail "must not write the default GNOME keyring (secret-tool store/clear/delete or libsecret store_sync)"
fi

if grep -nE 'secret-tool|keyring_store' "$ROOT/backends/secrets/pass-cli" \
  | grep -vE ':[0-9]+:[[:space:]]*#' | grep -q .; then
  fail "pass-cli backend must not call secret-tool or keyring_store"
fi
if grep -nE 'secret-tool|keyring_store' "$ROOT/backends/secrets/1password" | grep -q .; then
  fail "1password backend must not call secret-tool or keyring_store"
fi
grep -q '^export PROTON_PASS_LINUX_KEYRING=kernel$' "$ROOT/backends/secrets/pass-cli" \
  || fail "pass-cli backend must pin PROTON_PASS_LINUX_KEYRING=kernel"

# create_sync(service, label, alias, flags, cancellable) — alias must be None
python3 - "$STORE" <<'PY' || fail "create_sync must pass alias=None"
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(src)
found = False
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    func = node.func
    name = ""
    if isinstance(func, ast.Attribute) and func.attr == "create_sync":
        if isinstance(func.value, ast.Attribute) and func.value.attr == "Collection":
            name = "Collection.create_sync"
        elif isinstance(func.value, ast.Name) and func.value.id == "Collection":
            name = "Collection.create_sync"
    if name != "Collection.create_sync":
        continue
    found = True
    if len(node.args) < 3:
        raise SystemExit("Collection.create_sync missing alias argument")
    alias = node.args[2]
    if not isinstance(alias, ast.Constant) or alias.value is not None:
        raise SystemExit("Collection.create_sync alias must be None")
if not found:
    raise SystemExit("Collection.create_sync call not found")
print("create_sync alias ok")
PY

python3 - "$STORE" <<'PY' || fail "normalize_secret / default-collection unit tests"
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


class FakeCol:
    def __init__(self, path, label):
        self._path = path
        self._label = label

    def get_object_path(self):
        return self._path

    def get_label(self):
        return self._label


assert mod._is_default_collection(
    FakeCol("/org/freedesktop/secrets/collection/Default_5fkeyring", "Default keyring")
)
assert mod._is_default_collection(
    FakeCol("/org/freedesktop/secrets/collection/login", "Login")
)
assert mod._is_default_collection(
    FakeCol("/org/freedesktop/secrets/collection/login", "omaclone")
)
assert mod._is_default_collection(
    FakeCol("/org/freedesktop/secrets/aliases/default", "Passwords")
)
assert not mod._is_default_collection(
    FakeCol("/org/freedesktop/secrets/collection/omaclone", "omaclone")
)
assert not mod._is_default_collection(
    FakeCol("/org/freedesktop/secrets/collection/session", "")
)
assert mod._forbidden_collection_label("login")
assert mod._forbidden_collection_label("Default keyring")
assert not mod._forbidden_collection_label("omaclone")


class FakeSecret:
    class CollectionFlags:
        NONE = 0

    class Collection:
        @staticmethod
        def for_alias_sync(svc, alias, flags, cancellable):
            if alias == "default":
                return FakeCol("/org/freedesktop/secrets/collection/omaclone", "omaclone")
            return None


assert mod._is_default_collection(
    FakeCol("/org/freedesktop/secrets/collection/omaclone", "omaclone"),
    FakeSecret,
    object(),
), "collection aliased as default must be refused"
print("normalize/default-collection ok")
PY

if printf 'line1\nline2' | python3 "$STORE" put restic-password >/tmp/omaclone-keyring-test.err 2>&1; then
  fail "put of a multiline secret should fail before touching the keyring"
fi
grep -q newline /tmp/omaclone-keyring-test.err || fail "multiline put should mention newline"

# File store (test-only, no libsecret).
FILEKR=$(mktemp -d)
export OMACLONE_KEYRING_FILE="$FILEKR"
python3 "$STORE" available || fail "file store available should succeed"
python3 "$STORE" ensure || fail "file store ensure should succeed"
printf '%s' "file-store-secret" | python3 "$STORE" put s3-access-key --label "omaclone s3-access-key"
got=$(python3 "$STORE" get s3-access-key)
[[ "$got" == "file-store-secret" ]] || fail "file store get: $got"
mode=$(stat -c %a "$FILEKR/s3-access-key")
[[ "$mode" == 600 ]] || fail "file store secret mode $mode"
if printf 'line1\nline2' | python3 "$STORE" put s3-secret-key >/tmp/omaclone-keyring-file.err 2>&1; then
  fail "file store must still reject newlines"
fi
python3 "$STORE" delete s3-access-key
if python3 "$STORE" get s3-access-key >/dev/null 2>&1; then
  fail "file store delete did not remove s3-access-key"
fi
unset OMACLONE_KEYRING_FILE
rm -rf "$FILEKR"

# A fake secret-tool store/clear/delete must never be invoked on put/get/delete.
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT
cat >"$FAKE/secret-tool" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  store|clear|delete)
    echo "secret-tool $1 was called" >&2
    exit 99
    ;;
esac
exit 1
SH
chmod +x "$FAKE/secret-tool"
export PATH="$FAKE:$PATH"

if ! python3 "$STORE" available >/dev/null 2>&1; then
  echo "SKIP: libsecret/GNOME Keyring not available for round-trip test"
  echo OK
  exit 0
fi

# Production path: dedicated omaclone collection. Must not mutate the desktop
# keyring file or the default-alias pointer.
hash_file() {
  local f="$1"
  [[ -f "$f" ]] || { printf '%s\n' ""; return 0; }
  sha256sum -- "$f" | awk '{print $1}'
}

KR="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
DEFAULT_FILES=()
for f in "$KR/Default_keyring.keyring" "$KR/login.keyring" "$KR/default"; do
  [[ -f "$f" ]] && DEFAULT_FILES+=("$f")
done

ATTR="test-$(date +%s)-$$"
if ((${#DEFAULT_FILES[@]} > 0)); then
  before=()
  for f in "${DEFAULT_FILES[@]}"; do
    before+=("$(hash_file "$f")")
  done
  unset OMACLONE_KEYRING_USE_SESSION || true
  export OMACLONE_KEYRING_CREATE=0
  if printf '%s' "omaclone-keyring-isolation" | python3 "$STORE" put "$ATTR" --label "omaclone isolation test" 2>/tmp/omaclone-keyring-isolation.err; then
    i=0
    for f in "${DEFAULT_FILES[@]}"; do
      after=$(hash_file "$f")
      [[ "$after" == "${before[$i]}" ]] || fail "put mutated desktop keyring file: $f"
      i=$((i + 1))
    done
    python3 "$STORE" delete "$ATTR" >/dev/null 2>&1 || true
    i=0
    for f in "${DEFAULT_FILES[@]}"; do
      after=$(hash_file "$f")
      [[ "$after" == "${before[$i]}" ]] || fail "delete mutated desktop keyring file: $f"
      i=$((i + 1))
    done
  else
    if grep -q 'collection is missing' /tmp/omaclone-keyring-isolation.err; then
      echo "SKIP: omaclone collection not created; isolation test needs setup"
    else
      cat /tmp/omaclone-keyring-isolation.err >&2
      fail "put to omaclone collection failed"
    fi
  fi
fi

export OMACLONE_KEYRING_CREATE=0
export OMACLONE_KEYRING_USE_SESSION=1
ATTR="test-session-$(date +%s)-$$"
printf '%s' "omaclone-keyring-roundtrip" | python3 "$STORE" put "$ATTR" --label "omaclone test"
got=$(python3 "$STORE" get "$ATTR")
[[ "$got" == "omaclone-keyring-roundtrip" ]] || fail "session roundtrip mismatch: $got"
python3 "$STORE" delete "$ATTR"
if python3 "$STORE" get "$ATTR" >/dev/null 2>&1; then
  fail "delete did not remove $ATTR"
fi

echo OK
