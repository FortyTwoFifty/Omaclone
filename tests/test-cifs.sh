#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
export NAS_BACKUP_ROOT="$ROOT"
source "$ROOT/scripts/transport-lib.sh"

cifs_validate_unc "//nas/share" || fail "valid UNC should pass"
cifs_validate_unc "//nas/share,extra" && fail "comma UNC must fail"
cifs_validate_unc "//nas/share with space" && fail "space UNC must fail"
cifs_validate_unc "nas/share" && fail "missing slashes must fail"
cifs_validate_unc "//nas/foo/../etc" && fail ".. UNC must fail"
cifs_validate_unc "" && fail "empty UNC must fail"

grep -q 'vers=3.0' "$ROOT/backends/transport/cifs" || fail "cifs mount should request SMB3"
grep -q 'nosuid,nodev,noexec' "$ROOT/backends/transport/cifs" || fail "cifs mount should be nosuid,nodev,noexec"
grep -q 'cifs_validate_unc' "$ROOT/backends/transport/cifs" || fail "cifs setup should validate UNC"
echo OK
