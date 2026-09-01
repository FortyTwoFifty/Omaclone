#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
export NAS_BACKUP_USER_CONFIG_DIR
NAS_BACKUP_USER_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR"' EXIT
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"
mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets"
cp "$ROOT/tests/backends/secrets/dummy" "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/dummy"
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/dummy"

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/backend.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

nas_backup_backend_available secrets dummy || fail "dummy should be available"
got=$(nas_backup_backend_run secrets dummy get)
[[ "$got" == "dummy-password-not-for-real-repos" ]] || fail "dummy get mismatch: $got"

names=$(nas_backup_backend_available_names secrets)
printf '%s\n' "$names" | grep -qx dummy || fail "dummy not listed"
printf '%s\n' "$names" | grep -qx prompt || fail "prompt not listed"

nas_backup_backend_available secrets prompt || fail "prompt should be available"

nas_backup_backend_available secrets example && fail "example should not be available"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set secrets.backend dummy
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set secrets.keyring_offer declined
password_load </dev/null
[[ -n "${NAS_BACKUP_PWFD:-}" ]] || fail "pwfd unset"
[[ "$NAS_BACKUP_PWFILE" == /dev/fd/* ]] || fail "pwfile should be sealed /dev/fd: $NAS_BACKUP_PWFILE"
contents=$(password_fd_contents)
[[ "$contents" == "dummy-password-not-for-real-repos" ]] || fail "pwfile contents: $contents"
for _f in /dev/shm/omaclone.pw.* /run/user/"$(id -u)"/omaclone.pw.*; do
  [[ -f "$_f" ]] || continue
  fail "named password file still present after seal: $_f"
done
password_cleanup
[[ -z "${NAS_BACKUP_PWFD:-}" ]] || fail "pwfd not cleared"

if grep -q dummy-password "$NAS_BACKUP_CONFIG"; then
  fail "password leaked into config"
fi

nas_backup_backend_find secrets '../../../evil.sh' && fail "backend find must reject path traversal"
nas_backup_backend_name_ok '../x' && fail "backend name_ok must reject .."
nas_backup_backend_name_ok 'foo/bar' && fail "backend name_ok must reject slash"
nas_backup_backend_name_ok prompt || fail "backend name_ok should accept prompt"

echo "OK"
