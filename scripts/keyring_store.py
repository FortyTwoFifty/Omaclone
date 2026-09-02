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
import threading
import time
from typing import Any

SCHEMA_NAME = "org.omaclone.Secret"
LEGACY_SCHEMA_NAME = "org.freedesktop.Secret.Generic"
SERVICE = "omaclone"
LEGACY_SERVICES = ("omaclone", "omarchy-backup", "nas-backup")
DEFAULT_COLLECTION_LABEL = "omaclone"
# Labels/paths gnome-keyring uses for the desktop collection. Writing there
# rewrites the unencrypted GKeyFile and can make the daemon refuse to load it.
_DESKTOP_COLLECTION_LABELS = frozenset(
    {
        "default",
        "login",
        "default keyring",
        "login keyring",
    }
)
_DESKTOP_ALIASES = ("default", "login")


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


def _file_store_dir() -> str | None:
    # Test-only: a directory of attribute files instead of GNOME Keyring.
    # Production never sets OMACLONE_KEYRING_FILE.
    raw = os.environ.get("OMACLONE_KEYRING_FILE", "").strip()
    return raw or None


def _file_store_path(attribute: str) -> str:
    directory = _file_store_dir()
    if directory is None:
        raise RuntimeError("OMACLONE_KEYRING_FILE is not set")
    if (
        not attribute
        or attribute in {".", ".."}
        or "/" in attribute
        or "\\" in attribute
        or "\0" in attribute
    ):
        raise ValueError(f"invalid attribute name: {attribute!r}")
    return os.path.join(directory, attribute)


def file_store_put(attribute: str, secret: str) -> None:
    directory = _file_store_dir()
    if directory is None:
        raise RuntimeError("OMACLONE_KEYRING_FILE is not set")
    os.makedirs(directory, mode=0o700, exist_ok=True)
    path = _file_store_path(attribute)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, secret.encode("utf-8"))
    finally:
        os.close(fd)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def file_store_get(attribute: str) -> str | None:
    path = _file_store_path(attribute)
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return None
    return normalize_secret(data).decode("utf-8")


def file_store_delete(attribute: str) -> None:
    path = _file_store_path(attribute)
    try:
        os.remove(path)
    except FileNotFoundError:
        return


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
    cancellable = _cancellable(_timeout_seconds())
    try:
        return Secret.Service.get_sync(
            Secret.ServiceFlags.OPEN_SESSION | Secret.ServiceFlags.LOAD_COLLECTIONS,
            cancellable,
        )
    except Exception as exc:
        raise _cancelled_error(cancellable, exc, "connecting to GNOME Keyring") from exc


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
    return _is_interactive()


def _is_interactive() -> bool:
    flag = os.environ.get("OMACLONE_KEYRING_INTERACTIVE")
    if flag == "1":
        return True
    if flag == "0":
        return False
    try:
        if sys.stderr.isatty() or sys.stdin.isatty():
            return True
    except Exception:
        pass
    try:
        return os.isatty(2) or os.isatty(0)
    except Exception:
        return False


def _timeout_seconds(*, interactive: bool | None = None) -> float:
    raw = os.environ.get("OMACLONE_KEYRING_TIMEOUT")
    if raw:
        try:
            return max(0.1, float(raw))
        except ValueError:
            pass
    if interactive is None:
        interactive = _is_interactive()
    return 60.0 if interactive else 3.0


def _cancellable(seconds: float | None = None) -> Any:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio

    cancellable = Gio.Cancellable()
    if seconds is None:
        seconds = _timeout_seconds()
    if seconds <= 0:
        return cancellable

    def _cancel() -> None:
        time.sleep(seconds)
        try:
            cancellable.cancel()
        except Exception:
            pass

    threading.Thread(
        target=_cancel, daemon=True, name="omaclone-keyring-timeout"
    ).start()
    return cancellable


def _cancelled_error(cancellable: Any, exc: Exception, what: str) -> Exception:
    try:
        cancelled = bool(cancellable is not None and cancellable.is_cancelled())
    except Exception:
        cancelled = False
    if cancelled:
        return RuntimeError(
            f"Timed out {what}. If a keyring password dialog is open, it may "
            "be behind this window — dismiss or complete it, then retry."
        )
    return exc


def _collection_path(collection: Any) -> str:
    return (collection.get_object_path() or "").rstrip("/")


def _is_session_collection(collection: Any) -> bool:
    return _collection_path(collection).endswith("/collection/session")


def _forbidden_collection_label(label: str) -> bool:
    return label.strip().lower() in _DESKTOP_COLLECTION_LABELS


def _looks_like_desktop_collection(collection: Any) -> bool:
    path = _collection_path(collection).lower()
    label = (collection.get_label() or "").lower()
    if "default" in path or path.endswith("/collection/login"):
        return True
    return _forbidden_collection_label(label)


def _alias_collection(Secret: Any, svc: Any, alias: str) -> Any | None:
    try:
        flags = getattr(Secret.CollectionFlags, "NONE", 0)
        return Secret.Collection.for_alias_sync(svc, alias, flags, None)
    except Exception:
        return None


def _is_default_collection(
    collection: Any,
    Secret: Any | None = None,
    svc: Any | None = None,
) -> bool:
    if collection is None:
        return False
    if _is_session_collection(collection):
        return False
    if _looks_like_desktop_collection(collection):
        return True
    if Secret is None or svc is None:
        return False
    our = _collection_path(collection)
    if not our:
        return False
    for alias in _DESKTOP_ALIASES:
        aliased = _alias_collection(Secret, svc, alias)
        if aliased is not None and _collection_path(aliased) == our:
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
    locked = None
    for collection in collections:
        if collection.get_label() != want:
            continue
        if _is_default_collection(collection, Secret, svc):
            continue
        if not collection.get_locked():
            return collection
        if locked is None:
            locked = collection
    return locked


def _ensure_gcr_prompter() -> None:
    """Hyprland does not dbus-activate gcr-prompter with WAYLAND_DISPLAY, so
    Secret Service unlock dialogs never appear. Start it in this session."""
    path = "/usr/lib/gcr-prompter"
    if not os.path.isfile(path):
        return
    try:
        subprocess.check_output(["pgrep", "-x", "gcr-prompter"], stderr=subprocess.DEVNULL)
        return
    except (OSError, subprocess.CalledProcessError):
        pass
    try:
        subprocess.Popen(
            [path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env=os.environ.copy(),
        )
    except OSError:
        return
    time.sleep(0.4)


def _open_plain_session(conn: Any) -> str:
    from gi.repository import Gio, GLib

    result = conn.call_sync(
        "org.freedesktop.secrets",
        "/org/freedesktop/secrets",
        "org.freedesktop.Secret.Service",
        "OpenSession",
        GLib.Variant("(sv)", ("plain", GLib.Variant("s", ""))),
        GLib.VariantType("(vo)"),
        Gio.DBusCallFlags.NONE,
        5000,
        None,
    )
    return str(result.unpack()[1])


def _plain_master_args(conn: Any, collection_path: str, password: str) -> Any:
    """Secret struct for Unlock/CreateWithMasterPassword: plain session + raw bytes."""
    from gi.repository import GLib

    session_path = _open_plain_session(conn)
    return GLib.Variant(
        "(o(oayays))",
        (
            collection_path,
            (session_path, b"", password.encode("utf-8"), "text/plain"),
        ),
    )


def _unlock_with_master_password(svc: Any, collection: Any, password: str) -> None:
    """Unlock without a GUI prompt via gnome-keyring's private D-Bus API."""
    from gi.repository import Gio

    conn = svc.get_connection()
    args = _plain_master_args(conn, collection.get_object_path(), password)
    conn.call_sync(
        "org.freedesktop.secrets",
        "/org/freedesktop/secrets",
        "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface",
        "UnlockWithMasterPassword",
        args,
        None,
        Gio.DBusCallFlags.NONE,
        15000,
        None,
    )


def _tty_keyring_password() -> str:
    import getpass

    sys.stderr.write(
        "\nThe Omaclone secret store is locked.\n"
        "This is the GNOME Keyring *collection* password (if a dialog asked you\n"
        "to protect the Omaclone keyring). It is NOT:\n"
        "  • sudo / root\n"
        "  • your FIDO/security key\n"
        "  • the restic repository password (a different secret, unless you\n"
        "    deliberately reused the same string)\n"
        "If you never saw a keyring-password dialog, press Enter (empty) or\n"
        "recreate the store with: omaclone setup secrets\n\n"
    )
    sys.stderr.flush()
    try:
        return getpass.getpass("Omaclone keyring password: ")
    except (EOFError, OSError):
        return ""


def unlock_collection(
    svc: Any, collection: Any, *, interactive: bool | None = None
) -> None:
    if not collection.get_locked():
        return
    if interactive is None:
        interactive = _is_interactive()
    if not interactive:
        raise RuntimeError(
            "Omaclone keyring is locked. Unlock it from a terminal "
            "(omaclone location add / omaclone setup). FIDO cannot unlock it."
        )
    _ensure_gcr_prompter()
    password = _tty_keyring_password()
    try:
        _unlock_with_master_password(svc, collection, password)
        try:
            svc.load_collections_sync()
        except Exception:
            pass
        if not collection.get_locked():
            return
        found = find_collection(_gi_secret(), svc)
        if found is not None and not found.get_locked():
            return
    except Exception as exc:
        err = str(exc)
        if "Denied" in err or "invalid" in err.lower():
            print(
                "That password did not unlock the Omaclone keyring.\n"
                "The restic repository password is a different secret than this "
                "keyring, unless you deliberately reused the same string.\n"
                "Retry, press Enter if the keyring password was empty, or run: "
                "omaclone setup secrets",
                file=sys.stderr,
            )
        else:
            print(f"That password did not unlock the Omaclone keyring: {exc}", file=sys.stderr)
    print(
        "Falling back to a desktop unlock dialog. If none appears, gcr-prompter "
        "could not show a window on this compositor.",
        file=sys.stderr,
        flush=True,
    )
    cancellable = _cancellable(_timeout_seconds(interactive=True))
    try:
        svc.unlock_sync([collection], cancellable)
    except Exception as exc:
        raise _cancelled_error(
            cancellable, exc, "waiting for the keyring unlock dialog"
        ) from exc


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
    label = _collection_label()
    if _forbidden_collection_label(label):
        raise RuntimeError(
            f"refusing to create a collection named {label!r}; that is the "
            "desktop keyring"
        )
    # May prompt: that is how GNOME Keyring encrypts a new collection at rest.
    # Never pass alias=default/login — that would return the desktop keyring.
    print(
        "Create or unlock the Omaclone keyring if a password dialog appears "
        "(it may be behind this window).",
        file=sys.stderr,
        flush=True,
    )
    cancellable = _cancellable(_timeout_seconds(interactive=True))
    try:
        collection = Secret.Collection.create_sync(
            svc,
            label,
            None,
            Secret.CollectionCreateFlags.NONE,
            cancellable,
        )
    except Exception as exc:
        raise _cancelled_error(
            cancellable, exc, "creating the Omaclone keyring collection"
        ) from exc
    if collection is None or _is_default_collection(collection, Secret, svc):
        raise RuntimeError("refusing to use the default GNOME keyring collection")
    unlock_collection(svc, collection)
    return collection


def _attrs(attribute: str) -> dict[str, str]:
    return {"service": SERVICE, "attribute": attribute}


def store_item(
    Secret: Any,
    svc: Any,
    collection: Any,
    attribute: str,
    secret: str,
    label: str,
) -> None:
    if _is_default_collection(collection, Secret, svc):
        raise RuntimeError("refusing to write to the default GNOME keyring collection")
    value = Secret.Value.new(secret, -1, "text/plain")
    cancellable = _cancellable(_timeout_seconds())
    try:
        Secret.Item.create_sync(
            collection,
            _schema(Secret, SCHEMA_NAME),
            _attrs(attribute),
            label,
            value,
            Secret.ItemCreateFlags.REPLACE,
            cancellable,
        )
    except Exception as exc:
        raise _cancelled_error(
            cancellable, exc, "storing a secret in the Omaclone keyring"
        ) from exc


def lookup_in_collection(Secret: Any, collection: Any, attribute: str) -> str | None:
    if collection is None:
        return None
    flags = Secret.SearchFlags.LOAD_SECRETS
    if _is_interactive():
        flags = Secret.SearchFlags.UNLOCK | Secret.SearchFlags.LOAD_SECRETS
    cancellable = _cancellable(_timeout_seconds())
    for schema_name in (SCHEMA_NAME, LEGACY_SCHEMA_NAME):
        try:
            items = collection.search_sync(
                _schema(Secret, schema_name),
                _attrs(attribute),
                flags,
                cancellable,
            )
        except Exception as exc:
            raise _cancelled_error(
                cancellable, exc, "reading the Omaclone keyring"
            ) from exc
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


def cmd_recreate() -> int:
    """Create a new Omaclone collection with the password from stdin (may be empty).

    Used when the old collection is locked and the password is unknown.
    Does not delete the locked collection; find_collection prefers unlocked.
    """
    raw = sys.stdin.buffer.read().rstrip(b"\r\n")
    try:
        password = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return _die(str(exc))
    label = _collection_label()
    if _forbidden_collection_label(label):
        return _die(
            f"refusing to recreate a collection named {label!r}; that is the "
            "desktop keyring"
        )
    if _file_store_dir() is not None:
        try:
            os.makedirs(_file_store_dir() or "", mode=0o700, exist_ok=True)
        except OSError as exc:
            return _die(str(exc))
        return 0
    try:
        from gi.repository import Gio, GLib

        Secret = _gi_secret()
        svc = _service(Secret)
        conn = svc.get_connection()
        session_path = _open_plain_session(conn)
        args = GLib.Variant(
            "(a{sv}(oayays))",
            (
                {
                    "org.freedesktop.Secret.Collection.Label": GLib.Variant(
                        "s", label
                    )
                },
                (session_path, b"", password.encode("utf-8"), "text/plain"),
            ),
        )
        conn.call_sync(
            "org.freedesktop.secrets",
            "/org/freedesktop/secrets",
            "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface",
            "CreateWithMasterPassword",
            args,
            GLib.VariantType("(o)"),
            Gio.DBusCallFlags.NONE,
            15000,
            None,
        )
        svc.load_collections_sync()
        collection = find_collection(Secret, svc)
        if collection is None or collection.get_locked():
            return _die("recreate did not leave an unlocked Omaclone collection")
    except Exception as exc:
        return _die(str(exc))
    return 0


def cmd_available() -> int:
    if _file_store_dir() is not None:
        return 0
    try:
        Secret = _gi_secret()
        _service(Secret)
    except Exception as exc:
        return _die(f"GNOME Keyring (libsecret) is not available: {exc}")
    return 0


def cmd_ensure() -> int:
    directory = _file_store_dir()
    if directory is not None:
        try:
            os.makedirs(directory, mode=0o700, exist_ok=True)
        except OSError as exc:
            return _die(str(exc))
        return 0
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
    if _file_store_dir() is not None:
        try:
            file_store_put(attribute, secret)
        except (OSError, ValueError, RuntimeError) as exc:
            return _die(str(exc))
        return 0
    try:
        Secret = _gi_secret()
        svc = _service(Secret)
        collection = ensure_collection(Secret, svc, create=_allow_create())
        store_item(Secret, svc, collection, attribute, secret, label)
    except Exception as exc:
        return _die(str(exc))
    return 0


def cmd_get(attribute: str) -> int:
    if _file_store_dir() is not None:
        try:
            text = file_store_get(attribute)
        except (OSError, ValueError, RuntimeError) as exc:
            return _die(str(exc))
        if not text:
            return _die(f"no omaclone secret stored for {attribute}")
        sys.stdout.write(text)
        return 0
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
                store_item(Secret, svc, collection, attribute, secret, f"omaclone {attribute}")
            except Exception:
                pass
        sys.stdout.write(secret)
        return 0
    except Exception as exc:
        return _die(str(exc))


def cmd_delete(attribute: str) -> int:
    if _file_store_dir() is not None:
        try:
            file_store_delete(attribute)
        except (OSError, ValueError, RuntimeError) as exc:
            return _die(str(exc))
        return 0
    try:
        Secret = _gi_secret()
        svc = _service(Secret)
        collection = find_collection(Secret, svc)
        if collection is None:
            return 0
        flags = getattr(Secret.SearchFlags, "NONE", 0)
        if _is_interactive():
            flags = Secret.SearchFlags.UNLOCK
        cancellable = _cancellable(_timeout_seconds())
        try:
            items = collection.search_sync(
                _schema(Secret, SCHEMA_NAME),
                _attrs(attribute),
                flags,
                cancellable,
            )
        except Exception as exc:
            raise _cancelled_error(
                cancellable, exc, "searching the Omaclone keyring"
            ) from exc
        for item in items or []:
            item.delete_sync(cancellable)
    except Exception as exc:
        return _die(str(exc))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return _die(
            "usage: keyring_store.py available|ensure|recreate|get ATTRIBUTE|"
            "put ATTRIBUTE [--label LABEL]|delete ATTRIBUTE"
        )
    cmd = argv[1]
    if cmd == "available":
        return cmd_available()
    if cmd == "ensure":
        return cmd_ensure()
    if cmd == "recreate":
        return cmd_recreate()
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
