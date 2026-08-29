#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
export NAS_BACKUP_USER_CONFIG_DIR
NAS_BACKUP_USER_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR"' EXIT
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"

source "$ROOT/scripts/deps.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

for f in \
  "$ROOT/scripts/deps.sh" \
  "$ROOT/backends/secrets/1password" \
  "$ROOT/backends/secrets/pass-cli" \
  "$ROOT/backends/secrets/keyring" \
  "$ROOT/backends/secrets/prompt" \
  "$ROOT/backends/secrets/example" \
  "$ROOT/tests/backends/secrets/dummy" \
; do
  bash -n "$f" || fail "syntax error in $f"
done

echo "PASS: syntax checks"

if command -v gum >/dev/null 2>&1; then
  deps_ensure_pacman gum || fail "deps_ensure_pacman gum should be no-op when present"
fi

echo "PASS: deps_ensure_pacman no-op when present"

_FAKE_PACMAN_DIR=$(mktemp -d)
cat > "$_FAKE_PACMAN_DIR/pacman" <<'SH'
#!/usr/bin/env bash
echo "fake: refusing to install $*" >&2
exit 1
SH
chmod +x "$_FAKE_PACMAN_DIR/pacman"

_ORIG_PATH="$PATH"
export PATH="$_FAKE_PACMAN_DIR:$PATH"

die() { echo "DIE: $*" >&2; exit 1; }

if ! (deps_ensure_pacman nonexistent-fake-pkg >/dev/null 2>&1); then
  :
else
  fail "deps_ensure_pacman should fail with fake pacman"
fi

export PATH="$_ORIG_PATH"
rm -rf "$_FAKE_PACMAN_DIR"

echo "PASS: fake-pacman path for missing cmd"

if declare -F deps_curl_install >/dev/null; then
  :
else
  fail "deps_curl_install not defined in deps.sh"
fi

echo "PASS: deps_curl_install exists"

source "$ROOT/scripts/backend.sh"

mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets"
cp "$ROOT/tests/backends/secrets/dummy" "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/dummy"
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/dummy"

mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport"
cp "$ROOT/tests/backends/transport/dummy" "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport/dummy"
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport/dummy"

if ! grep -q '^install()' "$ROOT/backends/secrets/1password"; then
  fail "1password backend missing install()"
fi

if ! grep -q '^install()' "$ROOT/backends/secrets/pass-cli"; then
  fail "pass-cli backend missing install()"
fi

echo "PASS: backend install verbs defined"

nas_backup_backend_available secrets dummy || fail "dummy secret should be available"
if ! nas_backup_backend_ensure secrets dummy; then
  fail "ensure should succeed for already-available dummy secret"
fi

echo "PASS: ensure verb on dummy backends"

mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets"
cp "$ROOT/tests/backends/secrets/unavailable-until-installed" \
   "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/unavailable-until-installed"
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/unavailable-until-installed"

if nas_backup_backend_available secrets unavailable-until-installed; then
  fail "unavailable-until-installed should NOT be available yet"
fi

if ! nas_backup_backend_ensure secrets unavailable-until-installed; then
  fail "ensure should succeed after running install on unavailable backend"
fi

nas_backup_backend_available secrets unavailable-until-installed \
  || fail "unavailable-until-installed should now be available after ensure+install"

echo "PASS: ensure invokes install when unavailable"

all_names=$(nas_backup_backend_all_names secrets)
if printf '%s\n' "$all_names" | grep -qx example; then
  fail "choose_all (all_names) should exclude example from secrets backends"
fi

echo "PASS: choose_all excludes example"

if nas_backup_backend_run transport dummy definitely-not-a-verb >/dev/null 2>&1; then
  fail "unknown verb on dummy transport should fail"
fi

echo "PASS: unknown verb dispatch returns non-zero for dummy"

if ! grep -q 'setup_is_unfinished' "$ROOT/scripts/omaclone"; then
  fail "omaclone should reference setup_is_unfinished for resume gating"
fi

echo "PASS: resume still uses setup_is_unfinished"

for backend in prompt keyring pass-cli 1password example; do
  path="$ROOT/backends/secrets/$backend"
  [[ -f "$path" ]] || fail "shipped secret backend missing: $path"
  if ! grep -q '^install()' "$path"; then
    fail "secrets/$backend missing install()"
  fi
done

echo "PASS: all shipped secrets backends have install()"

for backend in sftp nfs cifs; do
  path="$ROOT/backends/transport/$backend"
  [[ -f "$path" ]] || fail "shipped transport backend missing: $path"
  if ! grep -q '^install()' "$path"; then
    fail "transport/$backend missing install()"
  fi
done

echo "PASS: transport backends with installs have install()"

if ! grep -q '^install()' "$ROOT/backends/notify/notify-send"; then
  fail "notify-send backend missing install()"
fi

echo "PASS: notify-send has install()"

echo ""
echo "OK"
