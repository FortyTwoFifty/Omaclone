#!/usr/bin/env bash
set -euo pipefail
set +x +v

uuid="${1:-}"
mountpoint="${2:-/mnt/omaclone}"
fstype="${3:-auto}"
[[ -n "$uuid" ]] || { echo "usage: install-disk-mount.sh UUID [mountpoint] [fstype]" >&2; exit 2; }

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
Options=noatime,nofail

[Install]
WantedBy=multi-user.target
EOF

sudo mkdir -p "$mountpoint"
sudo cp "$tmp/$unit_name" "$unit_dir/"
sudo systemctl daemon-reload
sudo systemctl enable --now "$unit_name"
echo "enabled $unit_name (UUID=$uuid -> $mountpoint)"
