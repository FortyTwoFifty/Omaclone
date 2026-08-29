#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

"$ROOT/scripts/omaclone" -h | grep -q forget || fail "usage missing forget"

export NAS_BACKUP_USER_CONFIG_DIR
NAS_BACKUP_USER_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR"' EXIT
export NAS_BACKUP_STATE_DIR="$NAS_BACKUP_USER_CONFIG_DIR/state"
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"
export OMACLONE_SKIP_SYSTEMD=1
unset NAS_BACKUP_LIB_LOADED OMACLONE_LOCATIONS_LOADED

set +e
out=$("$ROOT/scripts/omaclone" forget --yes --all 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "forget without transport should fail"
printf '%s\n' "$out" | grep -qi "transport" || fail "forget error should mention transport: $out"

echo OK
