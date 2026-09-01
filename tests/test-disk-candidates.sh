#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$ROOT/scripts/disk_candidates.py" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("disk_candidates", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

ESP = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
MSR = "e3c9e316-0b5c-4db8-817d-f92df00215ae"
BIOS = "21686148-6449-6e6f-744e-656564454649"

def paths(recs):
    return [r["path"] for r in recs]


def names(recs):
    return [r["name"] for r in recs]


# GPT USB NVMe enclosure: EFI + exFAT data (the live MP510 layout)
usb_nvme = {
    "blockdevices": [
        {
            "name": "nvme0n1",
            "path": "/dev/nvme0n1",
            "size": 1000000000000,
            "type": "disk",
            "fstype": None,
            "uuid": None,
            "mountpoint": None,
            "tran": "nvme",
            "hotplug": False,
            "label": None,
            "model": "System",
            "pkname": None,
            "parttype": None,
            "children": [
                {
                    "name": "nvme0n1p1",
                    "path": "/dev/nvme0n1p1",
                    "size": 536870912,
                    "type": "part",
                    "fstype": "vfat",
                    "uuid": "BOOT-EFI",
                    "mountpoint": "/boot",
                    "tran": None,
                    "hotplug": False,
                    "label": "EFI",
                    "model": None,
                    "pkname": "nvme0n1",
                    "parttype": ESP,
                },
                {
                    "name": "nvme0n1p2",
                    "path": "/dev/nvme0n1p2",
                    "size": 999000000000,
                    "type": "part",
                    "fstype": "btrfs",
                    "uuid": "root-uuid",
                    "mountpoint": "/",
                    "tran": None,
                    "hotplug": False,
                    "label": None,
                    "model": None,
                    "pkname": "nvme0n1",
                    "parttype": "0fc63daf-8483-4772-8e79-3d69d8477de4",
                },
            ],
        },
        {
            "name": "sdb",
            "path": "/dev/sdb",
            "size": 480103981056,
            "type": "disk",
            "fstype": None,
            "uuid": None,
            "mountpoint": None,
            "tran": "usb",
            "hotplug": True,
            "label": None,
            "model": "Force MP510",
            "pkname": None,
            "parttype": None,
            "children": [
                {
                    "name": "sdb1",
                    "path": "/dev/sdb1",
                    "size": 209715200,
                    "type": "part",
                    "fstype": "vfat",
                    "uuid": "67E3-17ED",
                    "mountpoint": None,
                    "tran": None,
                    "hotplug": True,
                    "label": "EFI",
                    "model": None,
                    "pkname": "sdb",
                    "parttype": ESP,
                },
                {
                    "name": "sdb2",
                    "path": "/dev/sdb2",
                    "size": 479894224896,
                    "type": "part",
                    "fstype": "exfat",
                    "uuid": "6A73-E22F",
                    "mountpoint": None,
                    "tran": None,
                    "hotplug": True,
                    "label": "MP510 Gen3",
                    "model": None,
                    "pkname": "sdb",
                    "parttype": "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
                },
            ],
        },
        {
            "name": "sda",
            "path": "/dev/sda",
            "size": 6000000000000,
            "type": "disk",
            "fstype": None,
            "uuid": None,
            "mountpoint": None,
            "tran": "iscsi",
            "hotplug": False,
            "label": None,
            "model": "iSCSI Disk",
            "pkname": None,
            "parttype": None,
            "children": [
                {
                    "name": "sda1",
                    "path": "/dev/sda1",
                    "size": 6000000000000,
                    "type": "part",
                    "fstype": "ext4",
                    "uuid": "steam-nas",
                    "mountpoint": "/mnt/SteamLibrary-NAS",
                    "tran": None,
                    "hotplug": False,
                    "label": "SteamLibrary-NAS",
                    "model": None,
                    "pkname": "sda",
                    "parttype": None,
                }
            ],
        },
        {
            "name": "nvme1n1",
            "path": "/dev/nvme1n1",
            "size": 2000000000000,
            "type": "disk",
            "fstype": None,
            "uuid": None,
            "mountpoint": None,
            "tran": "nvme",
            "hotplug": False,
            "label": None,
            "model": "Force MP600",
            "pkname": None,
            "parttype": None,
            "children": [
                {
                    "name": "nvme1n1p1",
                    "path": "/dev/nvme1n1p1",
                    "size": 2000000000000,
                    "type": "part",
                    "fstype": "ext4",
                    "uuid": "steam-nvme",
                    "mountpoint": "/mnt/SteamLibrary-NVMe",
                    "tran": None,
                    "hotplug": False,
                    "label": "Secondary NVMe",
                    "model": None,
                    "pkname": "nvme1n1",
                    "parttype": None,
                }
            ],
        },
        {
            "name": "loop0",
            "path": "/dev/loop0",
            "size": 8000000000,
            "type": "loop",
            "fstype": "ext4",
            "uuid": "loop-uuid",
            "mountpoint": None,
            "tran": None,
            "hotplug": False,
            "label": None,
            "model": None,
            "pkname": None,
            "parttype": None,
        },
    ]
}

system = {"nvme0n1", "nvme0n1p1", "nvme0n1p2"}
got = mod.iter_candidates(usb_nvme, system, allow_loop=False)
assert "/dev/sdb1" not in paths(got), f"EFI offered: {got}"
assert "/dev/sdb" not in paths(got), f"whole disk with children offered: {got}"
assert "/dev/nvme0n1p1" not in paths(got)
assert "/dev/nvme0n1p2" not in paths(got)
assert "/dev/loop0" not in paths(got)
assert paths(got)[0] == "/dev/sdb2", f"unmounted USB should sort first: {paths(got)}"
assert "/dev/sda1" in paths(got)
assert "/dev/nvme1n1p1" in paths(got)

# LUKS / swap / LVM / iso skipped
skip_fs = {
    "blockdevices": [
        {
            "name": "sdc",
            "path": "/dev/sdc",
            "size": 500000000000,
            "type": "disk",
            "children": [
                {
                    "name": "sdc1",
                    "path": "/dev/sdc1",
                    "size": 500000000000,
                    "type": "part",
                    "fstype": "crypto_LUKS",
                    "uuid": "luks-1",
                    "mountpoint": None,
                    "tran": "usb",
                    "hotplug": True,
                    "label": None,
                    "parttype": None,
                }
            ],
            "tran": "usb",
            "hotplug": True,
            "fstype": None,
            "uuid": None,
            "mountpoint": None,
            "label": None,
            "model": "LUKSStick",
            "parttype": None,
        },
        {
            "name": "sdd1",
            "path": "/dev/sdd1",
            "size": 8000000000,
            "type": "part",
            "fstype": "swap",
            "uuid": "swap-1",
            "mountpoint": "[SWAP]",
            "tran": "sata",
            "hotplug": False,
            "label": None,
            "model": None,
            "parttype": None,
        },
        {
            "name": "sde1",
            "path": "/dev/sde1",
            "size": 8000000000,
            "type": "part",
            "fstype": "LVM2_member",
            "uuid": "lvm-1",
            "mountpoint": None,
            "tran": "sata",
            "hotplug": False,
            "label": None,
            "model": None,
            "parttype": None,
        },
        {
            "name": "sr0",
            "path": "/dev/sr0",
            "size": 8000000000,
            "type": "rom",
            "fstype": "iso9660",
            "uuid": "iso-1",
            "mountpoint": None,
            "tran": "usb",
            "hotplug": True,
            "label": "ISO",
            "model": None,
            "parttype": None,
        },
    ]
}
got = mod.iter_candidates(skip_fs, set(), allow_loop=False)
assert got == [], f"skipped fstypes leaked: {got}"

# Blank USB disk, no partition table: format candidate
blank = {
    "blockdevices": [
        {
            "name": "sdf",
            "path": "/dev/sdf",
            "size": 8000000000,
            "type": "disk",
            "fstype": None,
            "uuid": None,
            "mountpoint": None,
            "tran": "usb",
            "hotplug": True,
            "label": None,
            "model": "Cruzer",
            "pkname": None,
            "parttype": None,
        }
    ]
}
got = mod.iter_candidates(blank, set(), allow_loop=False)
assert paths(got) == ["/dev/sdf"], got
assert got[0]["fstype"] == ""
assert got[0]["uuid"] == ""

# Sub-1G non-ESP is last-resort only
tiny_and_large = {
    "blockdevices": [
        {
            "name": "sdg1",
            "path": "/dev/sdg1",
            "size": 512 * 1024 * 1024,
            "type": "part",
            "fstype": "vfat",
            "uuid": "TINY-1",
            "mountpoint": None,
            "tran": "usb",
            "hotplug": True,
            "label": "KEYS",
            "model": "Tiny",
            "parttype": "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
        },
        {
            "name": "sdh1",
            "path": "/dev/sdh1",
            "size": 32 * 1024**3,
            "type": "part",
            "fstype": "ext4",
            "uuid": "BIG-1",
            "mountpoint": None,
            "tran": "usb",
            "hotplug": True,
            "label": "BACKUP",
            "model": "Big",
            "parttype": None,
        },
    ]
}
got = mod.iter_candidates(tiny_and_large, set(), allow_loop=False)
assert paths(got) == ["/dev/sdh1"], f"tiny should drop when a large volume exists: {paths(got)}"

tiny_only = {
    "blockdevices": [
        {
            "name": "sdg1",
            "path": "/dev/sdg1",
            "size": 512 * 1024 * 1024,
            "type": "part",
            "fstype": "vfat",
            "uuid": "TINY-1",
            "mountpoint": None,
            "tran": "usb",
            "hotplug": True,
            "label": "KEYS",
            "model": "Tiny",
            "parttype": "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
        }
    ]
}
got = mod.iter_candidates(tiny_only, set(), allow_loop=False)
assert paths(got) == ["/dev/sdg1"], f"tiny last-resort missing: {got}"

# EFI-only disk offers nothing
efi_only = {
    "blockdevices": [
        {
            "name": "sdi1",
            "path": "/dev/sdi1",
            "size": 209715200,
            "type": "part",
            "fstype": "vfat",
            "uuid": "EFI-ONLY",
            "mountpoint": None,
            "tran": "usb",
            "hotplug": True,
            "label": "EFI",
            "model": "Installer",
            "parttype": ESP,
        }
    ]
}
got = mod.iter_candidates(efi_only, set(), allow_loop=False)
assert got == [], f"ESP last-resort should still be skipped: {got}"

# BIOS boot + MSR skipped even when large
gpt_special = {
    "blockdevices": [
        {
            "name": "sdj1",
            "path": "/dev/sdj1",
            "size": 2 * 1024**3,
            "type": "part",
            "fstype": None,
            "uuid": None,
            "mountpoint": None,
            "tran": "sata",
            "hotplug": False,
            "label": None,
            "model": None,
            "parttype": BIOS,
        },
        {
            "name": "sdj2",
            "path": "/dev/sdj2",
            "size": 16 * 1024**3,
            "type": "part",
            "fstype": None,
            "uuid": None,
            "mountpoint": None,
            "tran": "sata",
            "hotplug": False,
            "label": None,
            "model": None,
            "parttype": MSR,
        },
    ]
}
got = mod.iter_candidates(gpt_special, set(), allow_loop=False)
assert got == [], f"BIOS/MSR offered: {got}"

# Loop allowed with flag
loop_data = {
    "blockdevices": [
        {
            "name": "loop0",
            "path": "/dev/loop0",
            "size": 8 * 1024**3,
            "type": "disk",
            "fstype": "ext4",
            "uuid": "loop-uuid",
            "mountpoint": None,
            "tran": None,
            "hotplug": False,
            "label": None,
            "model": None,
            "parttype": None,
        }
    ]
}
got = mod.iter_candidates(loop_data, set(), allow_loop=False)
assert got == []
got = mod.iter_candidates(loop_data, set(), allow_loop=True)
assert paths(got) == ["/dev/loop0"]

print("OK")
PY
