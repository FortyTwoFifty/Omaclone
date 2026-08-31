#!/usr/bin/env python3
"""Store omaclone secrets in a dedicated GNOME Keyring collection.

Never write to the default collection. Storing into that unencrypted file
rewrites every item; a newline in any of them (Proton VPN SSO, etc.) makes
gnome-keyring refuse to load it, which drops every other app's saved passwords. Omaclone uses its own collection so those rewrites cannot
happen. Creating that collection may prompt for a keyring password so the
secrets are encrypted at rest.
"""
from __future__ import annotations

import os
import subprocess
import sys
from typing import Any

SCHEMA_NAME = "org.omaclone.Secret"
LEGACY_SCHEMA_NAME = "org.freedesktop.Secret.Generic"
SERVICE = "omaclone"
LEGACY_SERVICES = ("omaclone", "omarchy-backup", "nas-backup")
DEFAULT_COLLECTION_LABEL = "omaclone"


def _die(message: str, code: int = 1) -> int:
    print(message, file=sys.stderr)
    return code


def normalize_secret(data: bytes) -> bytes:
    if b"\0" in data:
        raise ValueError("secret contains a NUL byte")
    data = data.rstrip(b"\r\n")
    if b"\n" in data or b"\r" in data:
        raise ValueError("secret contains a newline; refusing to store it")
    if not data:
        raise ValueError("empty secret")
    return data


def _gi_secret() -> Any:
    import gi

    gi.require_version("Secret", "1")
    from gi.repository import Secret

    return Secret


def _schema(Secret: Any, name: str) -> Any:
    return Secret.Schema.new(
        name,
        Secret.SchemaFlags.NONE,
        {
            "service": Secret.SchemaAttributeType.STRING,
            "attribute": Secret.SchemaAttributeType.STRING,
        },
    )


def _service(Secret: Any) -> Any:
    return Secret.Service.get_sync(
        Secret.ServiceFlags.OPEN_SESSION | Secret.ServiceFlags.LOAD_COLLECTIONS,
        None,
    )


def _collection_label() -> str:
    return os.environ.get("OMACLONE_KEYRING_COLLECTION", DEFAULT_COLLECTION_LABEL)


def _use_session() -> bool:
    return os.environ.get("OMACLONE_KEYRING_USE_SESSION") == "1"


def _allow_create() -> bool:
    flag = os.environ.get("OMACLONE_KEYRING_CREATE")
    if flag == "1":
        return True
    if flag == "0":
        return False
    return sys.stdin.isatty() or sys.stderr.isatty()


def _is_session_collection(collection: Any) -> bool:
    path = collection.get_object_path() or ""
    return path.rstrip("/").endswith("/collection/session")


def _is_default_collection(collection: Any) -> bool:
    path = (collection.get_object_path() or "").lower()
    label = (collection.get_label() or "").lower()
    if _is_session_collection(collection):
        return False
    if "default" in path or path.rstrip("/").endswith("/collection/login"):
        return True
    if label in {"default keyring", "login", "default"}:
        return True
    return False


def find_collection(Secret: Any, svc: Any) -> Any | None:
    collections = svc.get_collections() or []
    if _use_session():
        for collection in collections:
            if _is_session_collection(collection):
                return collection
        return None
    want = _collection_label()
    for collection in collections:
        if collection.get_label() == want and not _is_default_collection(collection):
            return collection
    return None


def unlock_collection(svc: Any, collection: Any) -> None:
    if collection.get_locked():
        svc.unlock_sync([collection], None)


def ensure_collection(Secret: Any, svc: Any, *, create: bool) -> Any:
    collection = find_collection(Secret, svc)
    if collection is not None:
        unlock_collection(svc, collection)
        return collection
    if not create:
        raise RuntimeError(
            "Omaclone keyring collection is missing. Run omaclone setup "
            "to create it (you will be asked for a keyring password)."
        )
    # May prompt: that is how GNOME Keyring encrypts a new collection at rest.
    # Never pass alias=default/login — that would return the desktop keyring.
    collection = Secret.Collection.create_sync(
        svc,
        _collection_label(),
        None,
        Secret.CollectionCreateFlags.NONE,
        None,
    )
    if collection is None or _is_default_collection(collection):
        raise RuntimeError("refusing to use the default GNOME keyring collection")
    unlock_collection(svc, collection)
    return collection


def _attrs(attribute: str) -> dict[str, str]:
    return {"service": SERVICE, "attribute": attribute}


def store_item(Secret: Any, collection: Any, attribute: str, secret: str, label: str) -> None:
    if _is_default_collection(collection):
        raise RuntimeError("refusing to write to the default GNOME keyring collection")
    value = Secret.Value.new(secret, -1, "text/plain")
    Secret.Item.create_sync(
        collection,
        _schema(Secret, SCHEMA_NAME),
        _attrs(attribute),
        label,
        value,
        Secret.ItemCreateFlags.REPLACE,
        None,
    )


def lookup_in_collection(Secret: Any, collection: Any, attribute: str) -> str | None:
    if collection is None:
        return None
    flags = Secret.SearchFlags.UNLOCK | Secret.SearchFlags.LOAD_SECRETS
    for schema_name in (SCHEMA_NAME, LEGACY_SCHEMA_NAME):
        items = collection.search_sync(
            _schema(Secret, schema_name),
            _attrs(attribute),
            flags,
            None,
        )
        for item in items or []:
            value = item.get_secret()
            if value is None:
                continue
            text = value.get_text()
            if text:
                return text
    return None


def lookup_legacy(attribute: str) -> bytes | None:
    secret_tool = _which("secret-tool")
    if secret_tool is None:
        return None
    for service in LEGACY_SERVICES:
        try:
            proc = subprocess.run(
                [secret_tool, "lookup", "service", service, "attribute", attribute],
                check=False,
                capture_output=True,
            )
        except OSError:
            return None
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout.rstrip(b"\r\n")
    return None


def _which(name: str) -> str | None:
    paths = os.environ.get("PATH", "").split(os.pathsep)
    for directory in paths:
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def cmd_available() -> int:
    try:
        Secret = _gi_secret()
        _service(Secret)
    except Exception as exc:
        return _die(f"GNOME Keyring (libsecret) is not available: {exc}")
    return 0


def cmd_ensure() -> int:
    try:
        Secret = _gi_secret()
        svc = _service(Secret)
        ensure_collection(Secret, svc, create=_allow_create())
    except Exception as exc:
        return _die(str(exc))
    return 0


def cmd_put(attribute: str, label: str) -> int:
    raw = sys.stdin.buffer.read()
    try:
        secret = normalize_secret(raw).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as exc:
        return _die(str(exc))
    try:
        Secret = _gi_secret()
        svc = _service(Secret)
        collection = ensure_collection(Secret, svc, create=_allow_create())
        store_item(Secret, collection, attribute, secret, label)
    except Exception as exc:
        return _die(str(exc))
    return 0


def cmd_get(attribute: str) -> int:
    try:
        Secret = _gi_secret()
        svc = _service(Secret)
        collection = find_collection(Secret, svc)
        if collection is not None:
            unlock_collection(svc, collection)
            text = lookup_in_collection(Secret, collection, attribute)
            if text:
                sys.stdout.write(text)
                return 0
        legacy = lookup_legacy(attribute)
        if not legacy:
            return _die(f"no omaclone secret stored for {attribute}")
        secret = normalize_secret(legacy).decode("utf-8")
        if collection is None and _allow_create():
            collection = ensure_collection(Secret, svc, create=True)
        if collection is not None:
            try:
                store_item(Secret, collection, attribute, secret, f"omaclone {attribute}")
            except Exception:
                pass
        sys.stdout.write(secret)
        return 0
    except Exception as exc:
        return _die(str(exc))


def cmd_delete(attribute: str) -> int:
    try:
        Secret = _gi_secret()
        svc = _service(Secret)
        collection = find_collection(Secret, svc)
        if collection is None:
            return 0
        flags = Secret.SearchFlags.UNLOCK
        items = collection.search_sync(
            _schema(Secret, SCHEMA_NAME),
            _attrs(attribute),
            flags,
            None,
        )
        for item in items or []:
            item.delete_sync(None)
    except Exception as exc:
        return _die(str(exc))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return _die(
            "usage: keyring_store.py available|ensure|get ATTRIBUTE|"
            "put ATTRIBUTE [--label LABEL]|delete ATTRIBUTE"
        )
    cmd = argv[1]
    if cmd == "available":
        return cmd_available()
    if cmd == "ensure":
        return cmd_ensure()
    if cmd == "get":
        if len(argv) != 3:
            return _die("usage: keyring_store.py get ATTRIBUTE")
        return cmd_get(argv[2])
    if cmd == "delete":
        if len(argv) != 3:
            return _die("usage: keyring_store.py delete ATTRIBUTE")
        return cmd_delete(argv[2])
    if cmd == "put":
        attribute = argv[2] if len(argv) >= 3 else ""
        if not attribute or attribute.startswith("-"):
            return _die("usage: keyring_store.py put ATTRIBUTE [--label LABEL]")
        label = f"omaclone {attribute}"
        rest = argv[3:]
        if rest[:1] == ["--label"] and len(rest) == 2:
            label = rest[1]
        elif rest:
            return _die("usage: keyring_store.py put ATTRIBUTE [--label LABEL]")
        return cmd_put(attribute, label)
    return _die(f"unknown verb: {cmd}", 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
