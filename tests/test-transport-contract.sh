#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
export NAS_BACKUP_USER_CONFIG_DIR
NAS_BACKUP_USER_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR"' EXIT
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"
mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport"
cp "$ROOT/tests/backends/transport/dummy" "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport/dummy"
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport/dummy"

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/backend.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

nas_backup_backend_available transport dummy || fail "dummy transport should be available"
nas_backup_transport_has dummy mount || fail "dummy should have mount"
nas_backup_transport_has dummy discover || fail "dummy should have discover"
nas_backup_transport_has dummy remote && fail "dummy should not have remote"

got=$(nas_backup_backend_run transport dummy discover)
printf '%s\n' "$got" | grep -q '"id":"dummy"' || fail "discover json: $got"

caps=$(nas_backup_transport_capabilities nfs)
[[ "$caps" == *mount* ]] || fail "nfs capabilities: $caps"

caps=$(nas_backup_transport_capabilities s3)
[[ "$caps" == *remote* ]] || fail "s3 capabilities: $caps"

if nas_backup_backend_run transport dummy definitely-not-a-verb 2>/dev/null; then
  fail "unknown verb should fail"
fi

dest=$(mktemp -d)
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
[[ -f "$dest/.omaclone-bootstrap" ]] || fail "missing bootstrap marker"
[[ -x "$dest/restore" ]] || fail "restore not executable"
[[ -d "$dest/omaclone" ]] || fail "missing omaclone tool tree"
[[ ! -d "$dest/omaclone/tests" ]] || fail "tests/ should not be copied"
[[ -f "$dest/SHA256SUMS" ]] || fail "missing SHA256SUMS"
grep -q 'scripts/omaclone' "$dest/SHA256SUMS" || fail "SHA256SUMS missing scripts/omaclone"
got=$(awk '$2=="scripts/omaclone"{print $1}' "$dest/SHA256SUMS")
want=$(sha256sum "$ROOT/scripts/omaclone" | awk '{print $1}')
[[ "$got" == "$want" ]] || fail "SHA256SUMS omaclone hash mismatch"
rm -rf "$dest"

echo "OK"
