#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import shutil
import stat
import sys
from pathlib import Path

SKIP_DIRS = {".git", "__pycache__", "tests"}
HASH_PATHS = ("scripts/omaclone", "scripts/restore", "scripts/lib.sh")

def plugin_version(root: Path) -> str:
    manifest = root / "manifest.json"
    if not manifest.is_file():
        return ""
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        if '"version"' in raw:
            return raw.split(":", 1)[-1].strip().strip('",')
    return ""


def copy_tree(src: Path, dest: Path, *, skip_tree: bool = False) -> None:
    if skip_tree and dest.is_dir():
        return
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        if item.name in SKIP_DIRS:
            continue
        target = dest / item.name
        if item.is_dir():
            shutil.copytree(item, target, ignore=shutil.ignore_patterns(*SKIP_DIRS, "*.pyc"))
        else:
            shutil.copy2(item, target)
            if item.name in {"restore"} or item.parent.name in {"scripts", "secrets", "transport", "notify"}:
                target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: bootstrap_copy.py ROOT DEST CONFIG", file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    dest = Path(argv[2]).resolve()
    config = Path(argv[3])
    dest.mkdir(parents=True, exist_ok=True)
    version = plugin_version(root)
    marker = dest / ".omaclone-bootstrap"
    skip_tree = False
    if marker.is_file() and version and marker.read_text(encoding="utf-8").strip() == f"omaclone {version}":
        skip_tree = (dest / "omaclone" / "scripts" / "omaclone").is_file()
    copy_tree(root, dest / "omaclone", skip_tree=skip_tree)
    restore_src = root / "scripts" / "restore"
    restore_dst = dest / "restore"
    shutil.copy2(restore_src, restore_dst)
    restore_dst.chmod(restore_dst.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    if config.is_file():
        shutil.copy2(config, dest / "config.toml")
        (dest / "config.toml").chmod(0o600)
    readme = root / "RESTORE.md"
    if readme.is_file():
        shutil.copy2(readme, dest / "RESTORE.md")
    lines = []
    for rel in HASH_PATHS:
        path = root / rel
        if path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            lines.append(f"{digest}  {rel}")
    (dest / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
    marker.write_text(f"omaclone {version}\n", encoding="utf-8")
    print(f"bootstrap installed at {dest}", file=sys.stderr)
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
