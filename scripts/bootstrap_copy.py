#!/usr/bin/env python3
from __future__ import annotations

import shutil
import stat
import sys
from pathlib import Path

SKIP_DIRS = {".git", "__pycache__", "tests"}

def copy_tree(src: Path, dest: Path) -> None:
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
    copy_tree(root, dest / "omaclone")
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
    marker = dest / ".omaclone-bootstrap"
    marker.write_text("omaclone\n", encoding="utf-8")
    print(f"bootstrap installed at {dest}", file=sys.stderr)
    return 0

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
