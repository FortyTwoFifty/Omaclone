#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export XDG_DATA_HOME="$home/.local/share"
unset NAS_BACKUP_USER_CONFIG_DIR NAS_BACKUP_CONFIG NAS_BACKUP_STATE_DIR NAS_BACKUP_LIB_LOADED
export NAS_BACKUP_ROOT="$ROOT"

mkdir -p "$XDG_CONFIG_HOME/nas-backup" "$XDG_DATA_HOME/nas-backup"
cat >"$XDG_CONFIG_HOME/nas-backup/config.toml" <<'EOF'
[restic]
repo = "/mnt/restic/repo"
[transport]
backend = "nfs"
EOF
printf '%s\n' '{"status":"ok","unix":1}' >"$XDG_DATA_HOME/nas-backup/last-result.json"

source "$ROOT/scripts/lib.sh"

[[ "$NAS_BACKUP_USER_CONFIG_DIR" == "$XDG_CONFIG_HOME/omaclone" ]] || fail "config dir: $NAS_BACKUP_USER_CONFIG_DIR"
[[ -f "$NAS_BACKUP_USER_CONFIG_DIR/config.toml" ]] || fail "migrated config missing"
grep -q '/mnt/restic/repo' "$NAS_BACKUP_USER_CONFIG_DIR/config.toml" || fail "repo not copied"
[[ -f "$NAS_BACKUP_STATE_DIR/last-result.json" ]] || fail "migrated state missing"
[[ ! -d "$NAS_BACKUP_USER_CONFIG_DIR/nas-backup" ]] || fail "nested nas-backup dir should not exist"
[[ ! -d "$NAS_BACKUP_USER_CONFIG_DIR/omarchy-backup" ]] || fail "nested omarchy-backup dir should not exist"
[[ -f "$XDG_CONFIG_HOME/nas-backup/config.toml" ]] || fail "legacy config should remain"

config_set destination.profile nas
config_set transport.backend nfs
config_set transport.uri "nas.example:/export"
card=$(write_recovery_card)
grep -E 'password\s*=' "$card" && fail "recovery card looks like it stored a secret"
grep -q 'nas.example:/export' "$card" || fail "locator missing from recovery card"
config_set transport.mountpoint "/mnt/omaclone"
card=$(write_recovery_card)
grep -q '/mnt/omaclone/omaclone/restore' "$card" || fail "recovery card restore path should be the kit launcher"

echo "OK"
