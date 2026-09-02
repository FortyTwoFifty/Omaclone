#!/usr/bin/env bash
set -euo pipefail
set +x +v

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
uuid="${1:-}"
mountpoint="${2:-/mnt/omaclone}"
fstype="${3:-auto}"
[[ -n "$uuid" ]] || { echo "usage: install-disk-mount.sh UUID [mountpoint] [fstype]" >&2; exit 2; }
# shellcheck source=/dev/null
source "$_script_dir/transport-lib.sh"
omaclone_disk_uuid_ok "$uuid" || { echo "invalid UUID" >&2; exit 2; }
[[ "$fstype" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid fstype" >&2; exit 2; }
mountpoint=$(omaclone_validate_mountpoint "$mountpoint") || exit 2
omaclone_privileged_load || exit 1

printf '%s\n' "sudo — touch your FIDO key if prompted. This is not the Omaclone keyring." >&2
omaclone_privileged install-disk --uuid "$uuid" --mountpoint "$mountpoint" --fstype "$fstype" \
  --uid "$(id -u)" --gid "$(id -g)"
