#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import shutil
import stat
import sys
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parent
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))
import kit_auth  # noqa: E402

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
KIT_TRANSPORT_KEYS = frozenset(
    {
        "backend",
        "uri",
        "endpoint",
        "bucket",
        "prefix",
        "region",
        "tls",
        "preset",
        "lookup",
        "host",
        "port",
        "username",
        "remote_path",
        "uuid",
        "device",
        "fstype",
        "mode",
        "mountpoint",
        "role_arn",
    }
)
KIT_DESTINATION_KEYS = frozenset({"profile", "vendor"})
KIT_NOTIFY_KEYS = frozenset({"backend"})
KIT_RESTORE_KEYS = frozenset({"profile"})
KIT_RETENTION_KEYS = frozenset({"preset"})
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


iter_hash_rels = kit_auth.iter_hash_rels
tree_digest = kit_auth.tree_digest
sha256sums_text = kit_auth.sha256sums_text
verify_sums = kit_auth.verify_sums


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
    if section == "transport":
        return key in KIT_TRANSPORT_KEYS
    if section == "destination":
        return key in KIT_DESTINATION_KEYS
    if section == "notify":
        return key in KIT_NOTIFY_KEYS
    if section == "restore":
        return key in KIT_RESTORE_KEYS
    if section == "retention":
        return key in KIT_RETENTION_KEYS
    if section == "locations":
        return key in {"ids", "active", "migrated"}
    if section.startswith("locations."):
        return key in KIT_TRANSPORT_KEYS | {"label", "backend", "schedule", "profile", "vendor", "repo"}
    if section in KIT_SECTIONS:
        return False
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
        skip_tree = (
            kit_root.is_dir()
            and (kit_root / "scripts" / "omaclone").is_file()
            and verify_sums(sums, kit_root)
            and kit_auth.verify_tree(kit_root)
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
    sig_src = root / kit_auth.SIG_REL
    sig_dst = dest / "omaclone" / kit_auth.SIG_REL
    if sig_src.is_file() and sig_src.resolve() != sig_dst.resolve():
        sig_dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sig_src, sig_dst)
    if not kit_auth.verify_tree(dest / "omaclone"):
        print(
            "omaclone: kit tree is not signed with the project key; restore will refuse it",
            file=sys.stderr,
        )
    marker.write_text(f"omaclone {version}\n", encoding="utf-8")
    print(f"bootstrap installed at {dest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
