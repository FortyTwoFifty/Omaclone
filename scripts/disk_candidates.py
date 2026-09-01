#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys

# GPT / MBR types that are never a clone target.
SKIP_PARTTYPES = {
    "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",  # EFI system
    "21686148-6449-6e6f-744e-656564454649",  # BIOS boot
    "e3c9e316-0b5c-4db8-817d-f92df00215ae",  # Microsoft reserved
    "de94bba4-06d1-4d40-a16a-bfd50179d6ac",  # Windows recovery
    "0xef",
    "ef",
}
ESP_LABELS = {"EFI", "ESP"}
FAT_TYPES = {"vfat", "fat", "fat32", "msdos"}
MIN_CANDIDATE_BYTES = 1024**3  # 1 GiB; smaller non-ESP kept only as a last resort


def lsblk() -> dict:
    pinned = os.environ.get("OMACLONE_LSBLK_JSON")
    if pinned:
        with open(pinned, encoding="utf-8") as fh:
            return json.load(fh)
    out = subprocess.check_output(
        [
            "lsblk",
            "-J",
            "-b",
            "-o",
            "NAME,PATH,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINT,TRAN,HOTPLUG,LABEL,MODEL,PKNAME,PARTTYPE",
        ],
        text=True,
    )
    return json.loads(out)


def flatten(nodes: list[dict], inherited: dict | None = None) -> list[dict]:
    inherited = inherited or {}
    rows: list[dict] = []
    for node in nodes:
        row = dict(node)
        for key in ("tran", "hotplug", "model"):
            if not row.get(key):
                row[key] = inherited.get(key)
        children = row.pop("children", None) or []
        row["_children"] = bool(children)
        rows.append(row)
        rows.extend(flatten(children, row))
    return rows


def names_for_mount(target: str) -> set[str]:
    try:
        src = subprocess.check_output(
            ["findmnt", "-n", "-o", "SOURCE", target],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return set()
    src = src.split("[", 1)[0].strip()
    if not src:
        return set()
    try:
        out = subprocess.check_output(
            ["lsblk", "-s", "-n", "-l", "-o", "NAME", src],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return {os.path.basename(src)}
    return {line.strip() for line in out.splitlines() if line.strip()}


def system_disk_names() -> set[str]:
    names: set[str] = set()
    for target in ("/", "/home", "/boot", "/boot/efi", "/efi"):
        names |= names_for_mount(target)
    return names


def human(nbytes: int | str | None) -> str:
    try:
        n = float(nbytes or 0)
    except (TypeError, ValueError):
        return "?"
    units = ("B", "K", "M", "G", "T", "P")
    i = 0
    while n >= 1024 and i < len(units) - 1:
        n /= 1024
        i += 1
    if i == 0:
        return f"{int(n)}B"
    return f"{n:.1f}{units[i]}"


def _bytes(row: dict) -> int:
    try:
        return int(row.get("size") or 0)
    except (TypeError, ValueError):
        return 0


def is_esp(row: dict) -> bool:
    parttype = str(row.get("parttype") or "").strip().lower()
    if parttype in SKIP_PARTTYPES:
        return True
    label = str(row.get("label") or "").strip().upper()
    fstype = str(row.get("fstype") or "").strip().lower()
    if label in ESP_LABELS and fstype in FAT_TYPES:
        return True
    return False


def is_removable(row: dict) -> bool:
    tran = str(row.get("tran") or "").lower()
    return tran == "usb" or bool(row.get("hotplug"))


def to_rec(row: dict) -> dict:
    name = row.get("name") or ""
    path = row.get("path") or f"/dev/{name}"
    return {
        "name": name,
        "path": path,
        "size": human(row.get("size")),
        "bytes": _bytes(row),
        "type": row.get("type") or "",
        "fstype": row.get("fstype") or "",
        "uuid": row.get("uuid") or "",
        "mountpoint": row.get("mountpoint") or "",
        "tran": row.get("tran") or "",
        "hotplug": bool(row.get("hotplug")),
        "label": row.get("label") or "",
        "model": row.get("model") or "",
    }


def sort_key(rec: dict) -> tuple:
    mounted = 1 if rec.get("mountpoint") else 0
    removable = 0 if (rec.get("tran") == "usb" or rec.get("hotplug")) else 1
    return (mounted, removable, rec.get("path") or "")


def iter_candidates(
    data: dict,
    system_names: set[str] | None = None,
    allow_loop: bool = False,
) -> list[dict]:
    system_names = system_names or set()
    skip_mounts = {"/", "/home", "/boot", "/boot/efi", "/efi", "[SWAP]"}
    skip_fstype = {"crypto_LUKS", "swap", "LVM2_member", "iso9660", "squashfs"}
    kept: list[dict] = []
    for row in flatten(data.get("blockdevices") or []):
        typ = row.get("type") or ""
        name = row.get("name") or ""
        if typ not in {"part", "disk", "lvm"}:
            continue
        if name.startswith("loop") and not allow_loop:
            continue
        if name.startswith("zram") or name.startswith("sr"):
            continue
        if name in system_names:
            continue
        mp = row.get("mountpoint") or ""
        if mp in skip_mounts:
            continue
        fstype = row.get("fstype") or ""
        if fstype in skip_fstype:
            continue
        if typ == "disk" and row.get("_children"):
            continue
        if is_esp(row):
            continue
        kept.append(to_rec(row))
    large = [rec for rec in kept if rec["bytes"] >= MIN_CANDIDATE_BYTES]
    chosen = large if large else kept
    chosen.sort(key=sort_key)
    for rec in chosen:
        rec.pop("bytes", None)
    return chosen


def main() -> int:
    allow_loop = os.environ.get("OMACLONE_ALLOW_LOOP") == "1" or os.environ.get("OMARCHY_BACKUP_ALLOW_LOOP") == "1"
    try:
        data = lsblk()
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, FileNotFoundError) as exc:
        print(f"disk_candidates: {exc}", file=sys.stderr)
        return 1
    system_names = system_disk_names()
    for rec in iter_candidates(data, system_names, allow_loop):
        print(json.dumps(rec, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
