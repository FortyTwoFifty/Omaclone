#!/usr/bin/env bash
set +x +v
set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n "$TARGET_HOME" ]] || { echo "cannot resolve home for $TARGET_USER" >&2; exit 1; }
export HOME="$TARGET_HOME"
export USER="$TARGET_USER"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
source "$ROOT/scripts/lib.sh"

STAGING="$NAS_BACKUP_STAGING"
mkdir -p "$STAGING"
chown -R "$TARGET_USER:" "$NAS_BACKUP_STATE_DIR" "$NAS_BACKUP_USER_CONFIG_DIR"

umask 077
_etc_tar_args=()
while IFS= read -r rel || [[ -n "$rel" ]]; do
  [[ -z "$rel" || "$rel" == \#* ]] && continue
  etc_rel_ok "$rel" || continue
  if [[ -e "/etc/$rel" ]]; then
    _etc_tar_args+=("etc/$rel")
  fi
done <"$ROOT/config/etc-restore.allow"
if ((${#_etc_tar_args[@]} > 0)); then
  tar --numeric-owner -C / -cf "$STAGING/etc.tar" "${_etc_tar_args[@]}"
else
  tar --numeric-owner -C / -cf "$STAGING/etc.tar" --files-from /dev/null
fi
unset _etc_tar_args rel

split_package_lists "$STAGING"

{
  echo "user=$TARGET_USER"
  echo "host=$(hostname)"
  echo "date=$(date --iso-8601=seconds)"
  echo "omarchy=$(omarchy version 2>/dev/null || true)"
} >"$STAGING/meta.txt"

lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS >"$STAGING/lsblk.txt" 2>/dev/null || true
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS >"$STAGING/findmnt.txt" 2>/dev/null || true
{
  echo "=== btrfs subvolumes ==="
  btrfs subvolume list / 2>/dev/null || true
} >"$STAGING/btrfs.txt"

systemctl --user --machine="$TARGET_USER@.host" list-unit-files --state=enabled --no-legend --no-pager \
  2>/dev/null | awk '{print $1}' | grep -E '\.(service|timer)$' >"$STAGING/user-units-enabled.txt" || true

cp -a "$ROOT/RESTORE.md" "$STAGING/RESTORE.md" 2>/dev/null || true
chown -R "$TARGET_USER:" "$STAGING"
chmod -R u=rwX,go= "$STAGING"
echo "prep wrote $STAGING"
