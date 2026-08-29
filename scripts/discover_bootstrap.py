#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

SKIP_PREFIXES = (
    "/proc",
    "/sys",
    "/dev",
    "/run/user",
    "/snap",
    "/var/lib/docker",
    "/var/lib/containers",
)
SKIP_EXACT = {"/", "/boot", "/efi", "/boot/efi"}

def backend_for_fstype(fstype: str) -> str:
    kind = (fstype or "").lower()
    if kind in {"nfs", "nfs4"}:
        return "nfs"
    if kind == "cifs":
        return "cifs"
    if kind in {"fuse.sshfs", "fuse.sftp"}:
        return "sftp"
    return "disk"

def _fstype(path: str) -> str:
    try:
        out = subprocess.check_output(
            ["findmnt", "-n", "-o", "FSTYPE", path],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return ""
    line = out.strip().splitlines()
    return line[0] if line else ""

def _targets() -> list[str]:
    pinned = os.environ.get("OMACLONE_DISCOVER_TARGETS")
    if pinned is not None:
        unique: list[str] = []
        seen: set[str] = set()
        for line in pinned.splitlines():
            t = line.strip()
            if not t or t in seen:
                continue
            seen.add(t)
            unique.append(t)
        return unique
    try:
        out = subprocess.check_output(
            ["findmnt", "-n", "-o", "TARGET", "-l"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return []
    targets = [line.strip() for line in out.splitlines() if line.strip()]
    home = Path.home() / "media"
    extra = [
        str(p)
        for p in (
            Path("/run/media") / os.environ.get("USER", ""),
            Path("/media") / os.environ.get("USER", ""),
            Path("/media"),
            home,
        )
        if p.is_dir()
    ]
    for root in extra:
        try:
            for child in Path(root).iterdir():
                if child.is_dir():
                    targets.append(str(child))
        except OSError:
            continue
    seen: set[str] = set()
    unique: list[str] = []
    for t in targets:
        if t not in seen:
            seen.add(t)
            unique.append(t)
    return unique

def _skip(path: str) -> bool:
    if path in SKIP_EXACT:
        return True
    home = str(Path.home())
    if path == home:
        return True
    return any(path == p or path.startswith(p + "/") for p in SKIP_PREFIXES)

def _is_bootstrap(dest: Path) -> bool:
    if (dest / ".omaclone-bootstrap").is_file():
        return True
    if (dest / "restore").is_file() and (dest / "config.toml").is_file():
        return True
    if (dest / "RESTORE.md").is_file() and (dest / "omaclone").is_dir():
        return True
    if (dest / "repo" / "config").is_file():
        return True
    return False

def _kit_dest(mount: Path) -> Path | None:
    nested = mount / "omaclone"
    try:
        if _is_bootstrap(nested):
            return nested
    except OSError:
        return None
    return None

def _resolve_identity(path: str) -> tuple:
    uuid = ""
    try:
        out = subprocess.check_output(
            ["findmnt", "-n", "-o", "UUID", path],
            text=True, stderr=subprocess.DEVNULL,
        )
        val = out.strip()
        if val:
            return ("uuid", val)
    except (OSError, subprocess.CalledProcessError):
        pass

    try:
        st = os.stat(path)
        return ("ino", st.st_dev, st.st_ino)
    except OSError:
        pass

    try:
        rp = str(Path(path).resolve())
    except OSError:
        rp = path
    return ("path", rp)

def _identity_uuid(identity: tuple) -> str:
    if len(identity) >= 2 and identity[0] == "uuid":
        return identity[1]
    return ""

def main() -> int:
    found = 0
    seen_identities: set[tuple] = set()
    for target in _targets():
        if _skip(target):
            continue
        dest = Path(target)
        try:
            if not dest.is_dir():
                continue
            kit = _kit_dest(dest)
            if kit is None:
                continue
        except OSError:
            continue
        identity = _resolve_identity(target)
        if identity in seen_identities:
            continue
        seen_identities.add(identity)
        label = dest.name or target
        rec = {
            "id": str(kit),
            "label": f"Backup at {label}",
            "uri": str(kit),
            "hint": label,
            "backend": backend_for_fstype(_fstype(target)),
            "config": str(kit / "config.toml") if (kit / "config.toml").is_file() else "",
            "restore": str(kit / "restore") if (kit / "restore").is_file() else "",
            "uuid": _identity_uuid(identity),
        }
        print(json.dumps(rec, separators=(",", ":")))
        found += 1
    return 0 if found else 0

if __name__ == "__main__":
    sys.exit(main())
