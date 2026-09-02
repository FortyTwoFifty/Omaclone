#!/usr/bin/env python3
"""Canonical kit tree digest and Ed25519 signatures (OpenSSL).

The public key is committed in config/omaclone-kit.pub and embedded in
scripts/restore. The private key is not in the tree. SHA256SUMS is a
human checksum list, not authentication.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SKIP_HASH_NAMES = frozenset({"omaclone-kit.sig", "TREE.sig"})
SKIP_DIRS = {".git", "__pycache__", "tests"}
SIG_REL = "config/omaclone-kit.sig"
PUB_REL = "config/omaclone-kit.pub"
NAMESPACE = "omaclone-kit-v1\n"

EMBEDDED_PUBKEY_PEM = """-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAxmJomSkS0fDbZLxJA6YNjedgar61rjmWrZJJD3icr0k=
-----END PUBLIC KEY-----
"""

PUBKEY_FINGERPRINT = "1e8c262255403241ba0ecfb32b956ff38d987c0f6b398feeb24fb97497556c44"


def iter_hash_rels(root: Path) -> list[str]:
    rels: list[str] = []
    for base in ("scripts", "backends", "config"):
        directory = root / base
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*")):
            if not path.is_file():
                continue
            if "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            if path.name in SKIP_HASH_NAMES:
                continue
            rels.append(path.relative_to(root).as_posix())
    return rels


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    digest.update(NAMESPACE.encode("utf-8"))
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


def _openssl(*args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["openssl", *args],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def sign_digest(digest_hex: str, key_path: Path) -> bytes:
    if not key_path.is_file():
        raise FileNotFoundError(f"signing key not found: {key_path}")
    payload = digest_hex.encode("ascii")
    with tempfile.NamedTemporaryFile(prefix="omaclone-digest.", delete=False) as tmp:
        tmp.write(payload)
        tmp_name = tmp.name
    try:
        proc = _openssl(
            "pkeyutl",
            "-sign",
            "-inkey",
            str(key_path),
            "-rawin",
            "-in",
            tmp_name,
        )
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode("utf-8", "replace") or "openssl sign failed")
        return proc.stdout
    finally:
        os.unlink(tmp_name)


def verify_digest(digest_hex: str, sig: bytes, pub_pem: str) -> bool:
    if not digest_hex or not sig or not pub_pem.strip():
        return False
    payload = digest_hex.encode("ascii")
    digest_tmp = sig_tmp = pub_tmp = None
    try:
        with tempfile.NamedTemporaryFile(prefix="omaclone-digest.", delete=False) as tmp:
            tmp.write(payload)
            digest_tmp = tmp.name
        with tempfile.NamedTemporaryFile(prefix="omaclone-sig.", delete=False) as tmp:
            tmp.write(sig)
            sig_tmp = tmp.name
        with tempfile.NamedTemporaryFile(prefix="omaclone-pub.", delete=False, mode="w", encoding="utf-8") as tmp:
            tmp.write(pub_pem if pub_pem.endswith("\n") else pub_pem + "\n")
            pub_tmp = tmp.name
        proc = _openssl(
            "pkeyutl",
            "-verify",
            "-pubin",
            "-inkey",
            pub_tmp,
            "-rawin",
            "-in",
            digest_tmp,
            "-sigfile",
            sig_tmp,
        )
        return proc.returncode == 0
    except OSError:
        return False
    finally:
        for path in (digest_tmp, sig_tmp, pub_tmp):
            if path:
                try:
                    os.unlink(path)
                except OSError:
                    pass


def load_pubkey(root: Path | None = None) -> str:
    if root is not None:
        path = root / PUB_REL
        if path.is_file():
            text = path.read_text(encoding="utf-8")
            if "BEGIN PUBLIC KEY" in text:
                return text
    return EMBEDDED_PUBKEY_PEM


def verify_tree(root: Path, sig_path: Path | None = None, pub_pem: str | None = None) -> bool:
    sig_path = sig_path or (root / SIG_REL)
    if not sig_path.is_file():
        return False
    sig = sig_path.read_bytes()
    if len(sig) < 32 or len(sig) > 256:
        return False
    digest = tree_digest(root)
    pem = pub_pem or EMBEDDED_PUBKEY_PEM
    if not verify_digest(digest, sig, pem):
        return False
    return True


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--digest":
        if len(argv) != 3:
            print("usage: kit_auth.py --digest ROOT", file=sys.stderr)
            return 2
        print(tree_digest(Path(argv[2]).resolve()))
        return 0
    if len(argv) >= 2 and argv[1] == "--verify":
        if len(argv) not in {3, 4}:
            print("usage: kit_auth.py --verify ROOT [SIG]", file=sys.stderr)
            return 2
        root = Path(argv[2]).resolve()
        sig = Path(argv[3]).resolve() if len(argv) == 4 else root / SIG_REL
        return 0 if verify_tree(root, sig) else 1
    if len(argv) >= 2 and argv[1] == "--sign":
        if len(argv) != 4:
            print("usage: kit_auth.py --sign KEY ROOT", file=sys.stderr)
            return 2
        key = Path(argv[2])
        root = Path(argv[3]).resolve()
        digest = tree_digest(root)
        sig = sign_digest(digest, key)
        dest = root / SIG_REL
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(sig)
        os.chmod(dest, 0o644)
        print(digest)
        return 0
    print("usage: kit_auth.py --digest|--verify|--sign ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
