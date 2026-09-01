#!/usr/bin/env bash
set -euo pipefail
set +x +v

uuid="${1:-}"
mountpoint="${2:-/mnt/omaclone}"
fstype="${3:-auto}"
[[ -n "$uuid" ]] || { echo "usage: install-disk-mount.sh UUID [mountpoint] [fstype]" >&2; exit 2; }
[[ "$uuid" =~ ^[0-9a-fA-F-]{8,36}$ ]] || { echo "invalid UUID" >&2; exit 2; }
[[ "$fstype" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid fstype" >&2; exit 2; }
opts="noatime,nofail,nosuid,nodev,noexec"
case "${fstype,,}" in
  vfat|exfat|ntfs|ntfs3|msdos|fuseblk)
    opts="$opts,uid=$(id -u),gid=$(id -g)"
    ;;
esac
case "$mountpoint" in
  /|/mnt|/home|/usr|/etc|/boot|/var|/root|/opt|/tmp|/dev|/proc|/sys|/run)
    echo "refusing to mount over $mountpoint" >&2
    exit 2
    ;;
esac

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

sudo mkdir -p "$mountpoint"
sudo cp "$tmp/$unit_name" "$unit_dir/"
sudo systemctl daemon-reload
sudo systemctl enable --now "$unit_name"
echo "enabled $unit_name (UUID=$uuid -> $mountpoint)"
