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
opts="noatime,nofail,nosuid,nodev,noexec"
case "${fstype,,}" in
  vfat|exfat|ntfs|ntfs3|msdos|fuseblk)
    opts="$opts,uid=$(id -u),gid=$(id -g)"
    ;;
esac
mountpoint=$(omaclone_validate_mountpoint "$mountpoint") || exit 2

unit_name=$(systemd-escape -p --suffix=mount "$mountpoint")
unit_dir=/etc/systemd/system

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/$unit_name" <<EOF
[Unit]
Description=Omaclone extra disk
After=local-fs.target

[Mount]
What=/dev/disk/by-uuid/$uuid
Where=$mountpoint
Type=$fstype
Options=$opts

[Install]
WantedBy=multi-user.target
EOF

printf '%s\n' "sudo — touch your FIDO key if prompted. This is not the Omaclone keyring." >&2
sudo_tty mkdir -p "$mountpoint"
sudo_tty cp "$tmp/$unit_name" "$unit_dir/"
sudo_tty systemctl daemon-reload
sudo_tty systemctl enable --now "$unit_name"
echo "enabled $unit_name (UUID=$uuid -> $mountpoint)"
