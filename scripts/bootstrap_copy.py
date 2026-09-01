#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import os
import re
import shutil
import stat
import sys
from pathlib import Path

SKIP_DIRS = {".git", "__pycache__", "tests"}
SECRET_KEY_RE = re.compile(r"(password|secret|token|credential|access.?key|secret.?key)", re.I)
KIT_SECTIONS = (
    "destination",
    "transport",
    "restic",
    "retention",
    "notify",
    "restore",
    "secrets",
    "locations",
)
KIT_SECRETS_KEYS = frozenset({"backend", "vault", "item", "field"})
KIT_RESTIC_KEYS = frozenset({"repo", "initialized"})
SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*$")
KV_RE = re.compile(r"^([A-Za-z0-9_.-]+)\s*=\s*(.*)$")


def plugin_version(root: Path) -> str:
    manifest = root / "manifest.json"
    if not manifest.is_file():
        return ""
    for raw in manifest.read_text(encoding="utf-8").splitlines():
        if '"version"' in raw:
            return raw.split(":", 1)[-1].strip().strip('",')
    return ""


def iter_hash_rels(root: Path) -> list[str]:
    rels: list[str] = []
    for base in ("scripts", "backends"):
        directory = root / base
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*")):
            if not path.is_file():
                continue
            if "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            rels.append(path.relative_to(root).as_posix())
    return rels


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for rel in iter_hash_rels(root):
        data = (root / rel).read_bytes()
        digest.update(rel.encode("utf-8") + b"\0" + data + b"\0")
    return digest.hexdigest()


def sha256sums_text(root: Path) -> str:
    lines = []
    for rel in iter_hash_rels(root):
        path = root / rel
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {rel}")
    return "\n".join(lines) + ("\n" if lines else "")


def verify_sums(sums: Path, root: Path) -> bool:
    expected = set(iter_hash_rels(root))
    listed: dict[str, str] = {}
    if not sums.is_file():
        return False
    for line in sums.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        listed[parts[-1]] = parts[0]
    if set(listed) != expected:
        return False
    for rel, want in listed.items():
        path = root / rel
        if not path.is_file():
            return False
        got = hashlib.sha256(path.read_bytes()).hexdigest()
        if got != want:
            return False
    return True


def _unquote(raw: str) -> str:
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1]
    return raw


def _quote(value: str) -> str:
    if value in ("true", "false") or re.fullmatch(r"-?\d+", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def load_config(path: Path) -> dict[str, dict[str, str]]:
    data: dict[str, dict[str, str]] = {}
    if not path.is_file():
        return data
    section = ""
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = SECTION_RE.match(stripped)
        if m:
            section = m.group(1)
            data.setdefault(section, {})
            continue
        m = KV_RE.match(stripped)
        if m and section:
            data[section][m.group(1)] = _unquote(m.group(2))
    return data


def _keep_key(section: str, key: str) -> bool:
    if SECRET_KEY_RE.search(key):
        return False
    if section == "secrets":
        return key in KIT_SECRETS_KEYS
    if section == "restic":
        return key in KIT_RESTIC_KEYS
    if section == "locations" or section.startswith("locations."):
        return True
    if section in KIT_SECTIONS:
        return True
    return False


def write_public_config(src: Path, dest: Path) -> None:
    data = load_config(src)
    lines: list[str] = []
    for section in sorted(data):
        kept = {k: v for k, v in data[section].items() if _keep_key(section, k)}
        if not kept:
            continue
        if lines:
            lines.append("")
        lines.append(f"[{section}]")
        for key in sorted(kept):
            lines.append(f"{key} = {_quote(kept[key])}")
    dest.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    os.chmod(dest, 0o600)


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
    if len(argv) >= 2 and argv[1] == "--digest":
        if len(argv) != 3:
            print("usage: bootstrap_copy.py --digest ROOT", file=sys.stderr)
            return 2
        print(tree_digest(Path(argv[2]).resolve()))
        return 0
    if len(argv) >= 2 and argv[1] == "--verify":
        if len(argv) != 4:
            print("usage: bootstrap_copy.py --verify SUMS ROOT", file=sys.stderr)
            return 2
        return 0 if verify_sums(Path(argv[2]), Path(argv[3]).resolve()) else 1
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
        kit_root = dest / "omaclone"
        sums = dest / "SHA256SUMS"
        skip_tree = kit_root.is_dir() and (kit_root / "scripts" / "omaclone").is_file() and verify_sums(
            sums, kit_root
        )
    copy_tree(root, dest / "omaclone", skip_tree=skip_tree)
    restore_src = root / "scripts" / "restore"
    restore_dst = dest / "restore"
    shutil.copy2(restore_src, restore_dst)
    restore_dst.chmod(restore_dst.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    if config.is_file():
        write_public_config(config, dest / "config.toml")
    readme = root / "RESTORE.md"
    if readme.is_file():
        shutil.copy2(readme, dest / "RESTORE.md")
    (dest / "SHA256SUMS").write_text(sha256sums_text(root), encoding="utf-8")
    marker.write_text(f"omaclone {version}\n", encoding="utf-8")
    print(f"bootstrap installed at {dest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
