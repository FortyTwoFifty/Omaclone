#!/usr/bin/env python3
from __future__ import annotations

import errno
import fcntl
import os
import re
import sys
sys.dont_write_bytecode = True
from pathlib import Path

SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*$")
KV_RE = re.compile(r"^([A-Za-z0-9_.-]+)\s*=\s*(.*)$")

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

def load(path: Path) -> dict[str, dict[str, str]]:
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

def _split_dotted(dotted: str) -> tuple[str, str]:
    if "." not in dotted:
        raise ValueError(f"config key must be section.key, got {dotted!r}")
    return dotted.rsplit(".", 1)

def get(path: Path, dotted: str, default: str = "") -> str:
    if "." not in dotted:
        return default
    section, key = _split_dotted(dotted)
    return load(path).get(section, {}).get(key, default)

def set_key(path: Path, dotted: str, value: str) -> None:
    if "." not in dotted:
        raise SystemExit(f"config key must be section.key, got {dotted!r}")
    section, key = _split_dotted(dotted)
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with open(lock_path, "a", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            _set_key_unlocked(path, section, key, value)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

def _set_key_unlocked(path: Path, section: str, key: str, value: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines() if path.is_file() else []
    out: list[str] = []
    in_section = False
    seen_section = False
    replaced = False
    current = ""
    for line in lines:
        stripped = line.strip()
        m = SECTION_RE.match(stripped)
        if m:
            if in_section and not replaced:
                out.append(f"{key} = {_quote(value)}")
                replaced = True
            current = m.group(1)
            in_section = current == section
            if in_section:
                seen_section = True
            out.append(line)
            continue
        km = KV_RE.match(stripped)
        if in_section and km and km.group(1) == key:
            out.append(f"{key} = {_quote(value)}")
            replaced = True
            continue
        out.append(line)
    if in_section and not replaced:
        out.append(f"{key} = {_quote(value)}")
        replaced = True
    if not seen_section:
        if out and out[-1].strip():
            out.append("")
        out.append(f"[{section}]")
        out.append(f"{key} = {_quote(value)}")
    text = "\n".join(out).rstrip() + "\n"
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    try:
        os.chmod(tmp, 0o600)
    except OSError as e:
        if e.errno != errno.EOPNOTSUPP:
            raise
    os.replace(tmp, path)

def drop_section(path: Path, section: str) -> None:
    if not path.is_file() or not section:
        return
    lock_path = path.with_name(path.name + ".lock")
    with open(lock_path, "a", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
            out: list[str] = []
            skipping = False
            for line in lines:
                m = SECTION_RE.match(line.strip())
                if m:
                    skipping = m.group(1) == section
                    if skipping:
                        continue
                if skipping:
                    continue
                out.append(line)
            text = ("\n".join(out).rstrip() + "\n") if out else ""
            tmp = path.with_name(path.name + ".tmp")
            tmp.write_text(text, encoding="utf-8")
            try:
                os.chmod(tmp, 0o600)
            except OSError as e:
                if e.errno != errno.EOPNOTSUPP:
                    raise
            os.replace(tmp, path)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

def dump_json(path: Path) -> None:
    import json

    print(json.dumps(load(path)))

def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: config.py <path> get|set|drop|dump [key] [value]", file=sys.stderr)
        return 2
    path = Path(argv[1])
    cmd = argv[2]
    if cmd == "get":
        print(get(path, argv[3] if len(argv) > 3 else "", argv[4] if len(argv) > 4 else ""), end="")
        return 0
    if cmd == "set":
        set_key(path, argv[3], argv[4] if len(argv) > 4 else "")
        return 0
    if cmd == "drop":
        drop_section(path, argv[3] if len(argv) > 3 else "")
        return 0
    if cmd == "dump":
        dump_json(path)
        return 0
    print(f"unknown command {cmd}", file=sys.stderr)
    return 2

if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
