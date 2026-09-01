#!/usr/bin/env bash
set +x +v
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
source "$ROOT/scripts/lib.sh"

STAGING="$NAS_BACKUP_STAGING"
if [[ -L "$STAGING" ]]; then
  echo "omaclone: refusing to write staging through a symlink: $STAGING" >&2
  exit 1
fi
parent=$(dirname "$STAGING")
mkdir -p "$parent"
chmod 700 "$parent" 2>/dev/null || true
fresh=$(mktemp -d "$parent/staging.XXXXXX")
chmod 700 "$fresh"
if [[ -e "$STAGING" ]]; then
  rm -rf "$STAGING"
fi
mv "$fresh" "$STAGING"

umask 077

_etc_members=()
while IFS= read -r rel || [[ -n "$rel" ]]; do
  [[ -z "$rel" || "$rel" == \#* ]] && continue
  etc_rel_ok "$rel" || continue
  [[ -L "/etc/$rel" ]] && continue
  if [[ -e "/etc/$rel" ]]; then
    _etc_members+=("etc/$rel")
  fi
done <"$ROOT/config/etc-restore.allow"

etc_tar="$STAGING/etc.tar"
if ((${#_etc_members[@]} > 0)); then
  if sudo -n tar --numeric-owner -C / -cf - "${_etc_members[@]}" >"$etc_tar" 2>/dev/null; then
    :
  elif [[ -t 0 && -t 1 ]] && sudo tar --numeric-owner -C / -cf - "${_etc_members[@]}" >"$etc_tar"; then
    :
  else
    tar --numeric-owner -C / -cf "$etc_tar" --files-from /dev/null
    echo "omaclone: skipped /etc collection (sudo tar failed); cloning \$HOME only extras" >&2
  fi
else
  tar --numeric-owner -C / -cf "$etc_tar" --files-from /dev/null
fi
unset _etc_members rel

split_package_lists "$STAGING"

{
  echo "user=${USER:-$(id -un)}"
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

systemctl --user list-unit-files --state=enabled --no-legend --no-pager \
  2>/dev/null | awk '{print $1}' | grep -E '\.(service|timer)$' >"$STAGING/user-units-enabled.txt" || true

cp -a "$ROOT/RESTORE.md" "$STAGING/RESTORE.md" 2>/dev/null || true
chmod -R u=rwX,go= "$STAGING"
echo "prep wrote $STAGING"
