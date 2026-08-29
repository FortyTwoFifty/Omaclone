#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys

def lsblk() -> dict:
    out = subprocess.check_output(
        [
            "lsblk",
            "-J",
            "-b",
            "-o",
            "NAME,PATH,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINT,TRAN,HOTPLUG,LABEL,MODEL,PKNAME",
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

def main() -> int:
    allow_loop = os.environ.get("OMACLONE_ALLOW_LOOP") == "1" or os.environ.get("OMARCHY_BACKUP_ALLOW_LOOP") == "1"
    try:
        data = lsblk()
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"disk_candidates: {exc}", file=sys.stderr)
        return 1
    system_names = system_disk_names()
    skip_mounts = {"/", "/home", "/boot", "/boot/efi", "/efi", "[SWAP]"}
    skip_fstype = {"crypto_LUKS", "swap", "LVM2_member", "iso9660", "squashfs"}
    for row in flatten(data.get("blockdevices") or []):
        typ = row.get("type") or ""
        name = row.get("name") or ""
        path = row.get("path") or f"/dev/{name}"
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
        rec = {
            "name": name,
            "path": path,
            "size": human(row.get("size")),
            "type": typ,
            "fstype": row.get("fstype") or "",
            "uuid": row.get("uuid") or "",
            "mountpoint": mp,
            "tran": row.get("tran") or "",
            "hotplug": bool(row.get("hotplug")),
            "label": row.get("label") or "",
            "model": row.get("model") or "",
        }
        print(json.dumps(rec, separators=(",", ":")))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
