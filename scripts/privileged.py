#!/usr/bin/env python3
"""Root-only helper. Accepts validated data, never user-staged unit files.

Invoked as `python3 -c <slurped-source> -- <command> ...` so sudo does not
reopen a user-writable pathname. Unit generation, exclusive no-follow
publication, ownership/mode checks, daemon-reload, enablement, rollback,
disk format revalidation, and /etc restore all live here.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
from pathlib import Path

ETC_ALLOWLIST = frozenset({"fido2"})
ETC_MAX_TAR_BYTES = 8 * 1024 * 1024
ETC_MAX_FILE_BYTES = 1024 * 1024
ETC_MAX_FILES = 64
UNIT_MODE = 0o644
DIR_MODE = 0o755
FILE_MODE = 0o644
MARKER = "# omaclone-managed=1\n"
UUID_RE = re.compile(r"^[0-9a-fA-F-]{8,36}$")
FSTYPE_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")
UNIT_NAME_RE = re.compile(r"^[A-Za-z0-9:_.\\-]+\.(mount|automount)$")
FAT_TYPES = {"vfat", "exfat", "ntfs", "ntfs3", "msdos", "fuseblk"}
SYSTEM_MOUNTS = ("/", "/home", "/boot", "/boot/efi", "/efi")
FORBIDDEN_MOUNTPOINTS = {
    "/",
    "/mnt",
    "/home",
    "/usr",
    "/etc",
    "/boot",
    "/var",
    "/root",
    "/opt",
    "/tmp",
    "/dev",
    "/proc",
    "/sys",
    "/run",
    "/var/tmp",
    "/dev/shm",
}


class Rejected(Exception):
    pass


def _euid() -> int:
    return os.geteuid()


def _test_mode() -> bool:
    return os.environ.get("OMACLONE_PRIVILEGED_TEST") == "1"


def _require_root() -> None:
    if _euid() != 0 and not _test_mode():
        raise Rejected("privileged helper must run as root")


def _unit_dir() -> str:
    return os.environ.get("OMACLONE_UNIT_DIR") or "/etc/systemd/system"


def _artifacts_path() -> str:
    return os.environ.get("OMACLONE_ARTIFACTS") or "/var/lib/omaclone/artifacts.json"


def _etc_root() -> str:
    return os.environ.get("OMACLONE_ETC_ROOT") or "/etc"


def _open_dir(path: str, *, follow: bool = False) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    if not follow:
        flags |= os.O_NOFOLLOW
    try:
        return os.open(path, flags)
    except OSError as exc:
        if not follow:
            raise Rejected(f"refusing to use {path}: {exc}") from exc
        raise


def _fstat_reg_or_dir(fd: int, *, directory: bool = False) -> os.stat_result:
    st = os.fstat(fd)
    if directory:
        if not stat.S_ISDIR(st.st_mode):
            raise Rejected("expected directory")
    elif not stat.S_ISREG(st.st_mode):
        raise Rejected("expected regular file")
    if _euid() == 0 and st.st_uid != 0:
        raise Rejected("path is not root-owned")
    return st


def validate_mountpoint(mp: str) -> str:
    mp = (mp or "").strip()
    if not mp:
        raise Rejected("mountpoint is required")
    mp = mp.rstrip("/") or "/"
    if not mp.startswith("/") or mp.startswith("//"):
        raise Rejected("mountpoint must be an absolute path")
    if any(ch in mp for ch in (" ", "\n", "\t", ",")):
        raise Rejected("mountpoint must be a single absolute path")
    if ".." in mp:
        raise Rejected("mountpoint must not contain ..")
    resolved = os.path.abspath(mp)
    if resolved in FORBIDDEN_MOUNTPOINTS:
        raise Rejected(f"refusing to mount over {resolved}")
    for prefix in ("/etc", "/boot", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/root", "/proc", "/sys", "/dev"):
        if resolved == prefix or resolved.startswith(prefix + "/"):
            raise Rejected(f"refusing to mount over {resolved}")
    home = os.environ.get("HOME") or ""
    if home and (resolved == home or resolved.startswith(home + "/")):
        raise Rejected("refusing to mount over $HOME")
    return resolved


def validate_uuid(uuid: str) -> str:
    uuid = (uuid or "").strip()
    if not UUID_RE.fullmatch(uuid) or ".." in uuid or "/" in uuid:
        raise Rejected("invalid UUID")
    return uuid


def validate_fstype(fstype: str) -> str:
    fstype = (fstype or "auto").strip() or "auto"
    if not FSTYPE_RE.fullmatch(fstype):
        raise Rejected("invalid fstype")
    return fstype


def validate_nfs_uri(uri: str) -> str:
    uri = (uri or "").strip()
    if not uri or any(ch in uri for ch in ("\n", "\t", ",")):
        raise Rejected("NFS URI must be a single host:/export value")
    if uri.startswith("//") or "://" in uri:
        raise Rejected("NFS URI must be host:/export")
    if uri.startswith("[") and "]:" in uri:
        host = uri[1 : uri.index("]:")]
        export = uri[uri.index("]:") + 2 :]
    elif ":" in uri:
        host, export = uri.split(":", 1)
    else:
        raise Rejected("NFS URI must be host:/export")
    export = export.rstrip("/") or "/"
    if not host or "/" in host or " " in host or host.startswith("-"):
        raise Rejected("NFS host is invalid")
    if not export.startswith("/"):
        raise Rejected("NFS export path must be absolute")
    return uri


def nfs_fstype() -> str:
    return "nfs4" if os.path.exists("/sbin/mount.nfs4") or os.path.exists("/usr/sbin/mount.nfs4") else "nfs"


def nfs_mount_options() -> str:
    return "rw,hard,nconnect=8,noatime,nosuid,nodev,noexec,proto=tcp,_netdev"


def disk_mount_options(fstype: str, uid: int | None, gid: int | None) -> str:
    opts = "noatime,nofail,nosuid,nodev,noexec"
    if fstype.lower() in FAT_TYPES and uid is not None and gid is not None:
        opts = f"{opts},uid={uid},gid={gid}"
    return opts


def systemd_escape_mount(mountpoint: str) -> str:
    proc = subprocess.run(
        ["systemd-escape", "-p", "--suffix=mount", mountpoint],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        raise Rejected("systemd-escape failed")
    name = proc.stdout.strip()
    if not UNIT_NAME_RE.fullmatch(name):
        raise Rejected("invalid unit name")
    return name


def nfs_unit_text(uri: str, mountpoint: str) -> tuple[str, str]:
    fstype = nfs_fstype()
    opts = nfs_mount_options()
    mount = (
        f"{MARKER}"
        "[Unit]\n"
        "Description=Omaclone NFS share\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n"
        "\n"
        "[Mount]\n"
        f"What={uri}\n"
        f"Where={mountpoint}\n"
        f"Type={fstype}\n"
        f"Options={opts}\n"
    )
    auto = (
        f"{MARKER}"
        "[Unit]\n"
        "Description=Automount Omaclone NFS share\n"
        "\n"
        "[Automount]\n"
        f"Where={mountpoint}\n"
        "TimeoutIdleSec=600\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )
    return mount, auto


def disk_unit_text(uuid: str, mountpoint: str, fstype: str, uid: int | None, gid: int | None) -> str:
    opts = disk_mount_options(fstype, uid, gid)
    return (
        f"{MARKER}"
        "[Unit]\n"
        "Description=Omaclone extra disk\n"
        "After=local-fs.target\n"
        "\n"
        "[Mount]\n"
        f"What=/dev/disk/by-uuid/{uuid}\n"
        f"Where={mountpoint}\n"
        f"Type={fstype}\n"
        f"Options={opts}\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )


def _content_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def publish_unit(unit_dir: str, name: str, content: str) -> str:
    if not UNIT_NAME_RE.fullmatch(name):
        raise Rejected("invalid unit name")
    if "\0" in content or MARKER not in content:
        raise Rejected("refusing to publish unmarked unit")
    data = content.encode("utf-8")
    dirfd = _open_dir(unit_dir)
    tmp_name = f".omaclone.{name}.tmp"
    fd = -1
    try:
        _fstat_reg_or_dir(dirfd, directory=True)
        try:
            os.unlink(tmp_name, dir_fd=dirfd)
        except FileNotFoundError:
            pass
        except OSError as exc:
            raise Rejected(f"cannot clear temp unit: {exc}") from exc
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
        fd = os.open(tmp_name, flags, UNIT_MODE, dir_fd=dirfd)
        written = 0
        while written < len(data):
            written += os.write(fd, data[written:])
        os.fchmod(fd, UNIT_MODE)
        if _euid() == 0:
            os.fchown(fd, 0, 0)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.rename(tmp_name, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        chk = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dirfd)
        try:
            st = _fstat_reg_or_dir(chk)
            if stat.S_ISLNK(st.st_mode):
                raise Rejected("unit became a symlink")
            if st.st_mode & 0o777 != UNIT_MODE:
                raise Rejected("unit mode is not 0644")
            got = os.read(chk, len(data) + 1)
            if got != data:
                raise Rejected("published unit content mismatch")
        finally:
            os.close(chk)
    finally:
        if fd >= 0:
            os.close(fd)
            try:
                os.unlink(tmp_name, dir_fd=dirfd)
            except OSError:
                pass
        os.close(dirfd)
    return _content_hash(content)


def _systemctl(*args: str) -> None:
    if _test_mode():
        return
    proc = subprocess.run(["systemctl", *args], check=False)
    if proc.returncode != 0:
        raise Rejected(f"systemctl {' '.join(args)} failed")


def _mkdir_p(path: str) -> None:
    if _test_mode():
        return
    subprocess.run(["mkdir", "-p", "--", path], check=True)


def load_artifacts() -> dict:
    path = _artifacts_path()
    try:
        raw = Path(path).read_text(encoding="utf-8")
        data = json.loads(raw)
        if isinstance(data, dict):
            data.setdefault("units", [])
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {"units": []}


def save_artifacts(data: dict) -> None:
    path = _artifacts_path()
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    payload = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")
    dirfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    tmp = ".artifacts.json.tmp"
    fd = -1
    try:
        try:
            os.unlink(tmp, dir_fd=dirfd)
        except FileNotFoundError:
            pass
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644, dir_fd=dirfd)
        os.write(fd, payload)
        if _euid() == 0:
            os.fchown(fd, 0, 0)
        os.fchmod(fd, 0o644)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.rename(tmp, os.path.basename(path), src_dir_fd=dirfd, dst_dir_fd=dirfd)
    finally:
        if fd >= 0:
            os.close(fd)
        os.close(dirfd)


def record_units(entries: list[dict]) -> None:
    data = load_artifacts()
    by_name = {u.get("name"): u for u in data.get("units", []) if isinstance(u, dict)}
    for entry in entries:
        by_name[entry["name"]] = entry
    data["units"] = list(by_name.values())
    save_artifacts(data)


def rollback_units(unit_dir: str, names: list[str], mountpoint: str | None = None) -> None:
    for name in names:
        if not UNIT_NAME_RE.fullmatch(name):
            continue
        try:
            _systemctl("disable", "--now", "--", name)
        except Rejected:
            pass
        try:
            _systemctl("stop", "--", name)
        except Rejected:
            pass
        dirfd = _open_dir(unit_dir)
        try:
            os.unlink(name, dir_fd=dirfd)
        except FileNotFoundError:
            pass
        except OSError:
            pass
        finally:
            os.close(dirfd)
    if mountpoint and not _test_mode():
        subprocess.run(["umount", "-l", "--", mountpoint], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        _systemctl("daemon-reload")
    except Rejected:
        pass


def install_nfs(uri: str, mountpoint: str) -> None:
    _require_root()
    uri = validate_nfs_uri(uri)
    mountpoint = validate_mountpoint(mountpoint)
    unit_dir = _unit_dir()
    mount_name = systemd_escape_mount(mountpoint)
    auto_name = mount_name[: -len(".mount")] + ".automount"
    if not UNIT_NAME_RE.fullmatch(auto_name):
        raise Rejected("invalid automount unit name")
    mount_text, auto_text = nfs_unit_text(uri, mountpoint)
    names = [mount_name, auto_name]
    try:
        _mkdir_p(mountpoint)
        h1 = publish_unit(unit_dir, mount_name, mount_text)
        h2 = publish_unit(unit_dir, auto_name, auto_text)
        _systemctl("daemon-reload")
        _systemctl("enable", "--now", "--", auto_name)
        _systemctl("start", "--", mount_name)
        record_units(
            [
                {"name": mount_name, "sha256": h1, "kind": "nfs-mount", "mountpoint": mountpoint},
                {"name": auto_name, "sha256": h2, "kind": "nfs-automount", "mountpoint": mountpoint},
            ]
        )
    except Exception:
        rollback_units(unit_dir, names, mountpoint)
        raise
    print(f"enabled {auto_name} ({uri} -> {mountpoint})", file=sys.stderr)


def install_disk(uuid: str, mountpoint: str, fstype: str, uid: int | None, gid: int | None) -> None:
    _require_root()
    uuid = validate_uuid(uuid)
    mountpoint = validate_mountpoint(mountpoint)
    fstype = validate_fstype(fstype)
    unit_dir = _unit_dir()
    name = systemd_escape_mount(mountpoint)
    text = disk_unit_text(uuid, mountpoint, fstype, uid, gid)
    try:
        _mkdir_p(mountpoint)
        digest = publish_unit(unit_dir, name, text)
        _systemctl("daemon-reload")
        _systemctl("enable", "--now", "--", name)
        record_units([{"name": name, "sha256": digest, "kind": "disk-mount", "mountpoint": mountpoint, "uuid": uuid}])
    except Exception:
        rollback_units(unit_dir, [name], mountpoint)
        raise
    print(f"enabled {name} (UUID={uuid} -> {mountpoint})", file=sys.stderr)


def _unit_hash_at(unit_dir: str, name: str) -> str | None:
    dirfd = _open_dir(unit_dir)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dirfd)
    except OSError:
        os.close(dirfd)
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
            if len(data) > 1024 * 1024:
                return None
        if MARKER.encode("utf-8") not in data:
            return None
        return hashlib.sha256(data).hexdigest()
    finally:
        os.close(fd)
        os.close(dirfd)


def uninstall_units() -> None:
    _require_root()
    unit_dir = _unit_dir()
    data = load_artifacts()
    kept: list[dict] = []
    removed: list[str] = []
    for entry in data.get("units", []):
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "")
        want = str(entry.get("sha256") or "")
        if not UNIT_NAME_RE.fullmatch(name) or not want:
            kept.append(entry)
            continue
        got = _unit_hash_at(unit_dir, name)
        if got is None:
            continue
        if got != want:
            print(f"leaving {name}: content does not match this installation", file=sys.stderr)
            kept.append(entry)
            continue
        try:
            _systemctl("disable", "--now", "--", name)
        except Rejected:
            pass
        dirfd = _open_dir(unit_dir)
        try:
            os.unlink(name, dir_fd=dirfd)
        except OSError as exc:
            print(f"could not remove {name}: {exc}", file=sys.stderr)
            kept.append(entry)
            continue
        finally:
            os.close(dirfd)
        removed.append(name)
    if removed:
        try:
            _systemctl("daemon-reload")
        except Rejected:
            pass
    data["units"] = kept
    save_artifacts(data)
    if removed:
        print("removed " + ", ".join(removed), file=sys.stderr)
    else:
        print("no omaclone system units removed", file=sys.stderr)


def _majmin_from_stat(st: os.stat_result) -> str:
    return f"{os.major(st.st_rdev)}:{os.minor(st.st_rdev)}"


def _sysfs_size(majmin: str) -> int:
    path = f"/sys/dev/block/{majmin}/size"
    try:
        with open(path, encoding="utf-8") as fh:
            sectors = int(fh.read().strip())
        return sectors * 512
    except (OSError, ValueError) as exc:
        raise Rejected(f"could not read size for {majmin}") from exc


def _sysfs_name(majmin: str) -> str:
    path = f"/sys/dev/block/{majmin}"
    try:
        return os.path.basename(os.path.realpath(path))
    except OSError:
        return ""


def _parent_names(name: str) -> set[str]:
    names = {name}
    sysdir = f"/sys/class/block/{name}"
    try:
        pk = Path(sysdir, "pkname")
        # pkname is an lsblk field; walk slaves/holders plus dirname of /sys/class/block/name
        parent = os.path.dirname(os.path.realpath(sysdir))
        if os.path.basename(parent):
            names.add(os.path.basename(os.path.dirname(os.path.realpath(sysdir))))
    except OSError:
        pass
    # Walk up via partition sysfs (../) until a disk.
    cur = Path(f"/sys/class/block/{name}")
    for _ in range(4):
        try:
            if (cur / "partition").is_file():
                cur = cur.parent
                names.add(cur.name)
                continue
        except OSError:
            break
        break
    slaves = Path(f"/sys/class/block/{name}/slaves")
    try:
        for slave in slaves.iterdir():
            names.add(slave.name)
    except OSError:
        pass
    return {n for n in names if n}


def _mountinfo_devices() -> dict[str, str]:
    """maj:min -> mountpoint for block mounts."""
    out: dict[str, str] = {}
    try:
        with open("/proc/self/mountinfo", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 10:
                    continue
                majmin = parts[2]
                target = parts[4]
                out.setdefault(majmin, target)
    except OSError:
        pass
    return out


def _system_block_names() -> set[str]:
    names: set[str] = set()
    mounts = _mountinfo_devices()
    for target in SYSTEM_MOUNTS:
        for majmin, mp in mounts.items():
            if mp == target:
                name = _sysfs_name(majmin)
                if name:
                    names |= _parent_names(name)
    return names


def _resolve_by_id(by_id: str) -> os.stat_result:
    if not by_id.startswith("/dev/disk/by-id/"):
        raise Rejected("by-id path must be under /dev/disk/by-id/")
    if ".." in by_id or "\n" in by_id:
        raise Rejected("invalid by-id path")
    try:
        st = os.stat(by_id, follow_symlinks=True)
    except OSError as exc:
        raise Rejected(f"by-id node missing: {by_id}") from exc
    if not stat.S_ISBLK(st.st_mode):
        raise Rejected("by-id path is not a block device")
    return st


def check_disk_identity(
    path: str,
    majmin: str,
    size_bytes: int,
    by_id: str,
    serial: str,
    pkname: str,
) -> str:
    if not path.startswith("/dev/") or ".." in path:
        raise Rejected("device path must be under /dev/")
    try:
        st = os.stat(path, follow_symlinks=True)
    except OSError as exc:
        raise Rejected(f"device missing: {path}") from exc
    if not stat.S_ISBLK(st.st_mode):
        raise Rejected(f"{path} is not a block device")
    got_mm = _majmin_from_stat(st)
    if got_mm != majmin:
        raise Rejected(f"device identity changed: {path} is {got_mm}, expected {majmin}")
    if by_id:
        bid = _resolve_by_id(by_id)
        if _majmin_from_stat(bid) != majmin:
            raise Rejected("by-id node does not match the selected device")
    got_size = _sysfs_size(majmin)
    if size_bytes > 0 and got_size != size_bytes:
        raise Rejected(f"device size changed: have {got_size}, expected {size_bytes}")
    name = _sysfs_name(majmin)
    if not name:
        raise Rejected("could not resolve sysfs name")
    sys_names = _system_block_names()
    cand_names = _parent_names(name)
    if pkname:
        cand_names.add(pkname)
    if cand_names & sys_names:
        raise Rejected("refusing to format a system disk or its partition")
    mounts = _mountinfo_devices()
    if majmin in mounts:
        raise Rejected(f"device is mounted at {mounts[majmin]}")
    if serial:
        serial_path = f"/sys/class/block/{name}/device/serial"
        try:
            got_serial = Path(serial_path).read_text(encoding="utf-8").strip()
            if got_serial and got_serial != serial:
                raise Rejected("device serial changed")
        except OSError:
            pass
    return name


def format_disk(
    path: str,
    majmin: str,
    size_bytes: int,
    by_id: str,
    serial: str,
    pkname: str,
    label: str,
) -> None:
    _require_root()
    if label and (len(label) > 16 or any(ch in label for ch in ("\n", "\t", "/", "\0"))):
        raise Rejected("invalid filesystem label")
    open_path = by_id if by_id else path
    name = check_disk_identity(path, majmin, size_bytes, by_id, serial, pkname)
    if by_id:
        check_disk_identity(open_path, majmin, size_bytes, by_id, serial, pkname)
    if _test_mode():
        print(f"would mkfs.ext4 {open_path} ({name} {majmin})", file=sys.stderr)
        return
    flags = os.O_RDWR | os.O_CLOEXEC
    try:
        fd = os.open(open_path, flags)
    except OSError as exc:
        raise Rejected(f"could not open {open_path}: {exc}") from exc
    try:
        st = os.fstat(fd)
        if not stat.S_ISBLK(st.st_mode):
            raise Rejected("held fd is not a block device")
        if _majmin_from_stat(st) != majmin:
            raise Rejected("device identity changed before mkfs")
        check_disk_identity(path, majmin, size_bytes, by_id, serial, pkname)
        proc_path = f"/proc/self/fd/{fd}"
        cmd = ["mkfs.ext4", "-F"]
        if label:
            cmd.extend(["-L", label])
        cmd.append(proc_path)
        proc = subprocess.run(cmd, check=False)
        if proc.returncode != 0:
            raise Rejected("mkfs.ext4 failed")
    finally:
        os.close(fd)
    print(f"formatted {path} as ext4", file=sys.stderr)


def _tar_name_ok(name: str) -> str | None:
    name = name.replace("\\", "/").lstrip("./")
    if not name or name.startswith("/") or name.startswith("../") or "/../" in name or name.endswith("/.."):
        return None
    if "\0" in name or name.startswith("etc/../") or "/./" in name:
        return None
    if name == "etc" or name.startswith("etc/"):
        rel = name[4:].lstrip("/")
        if not rel:
            return ""
        top = rel.split("/", 1)[0]
        if top not in ETC_ALLOWLIST:
            return None
        if any(p in ("", ".", "..") for p in rel.split("/")):
            return None
        return rel
    return None


def extract_etc_members(tar_path: str) -> list[tuple[str, bytes, bool]]:
    """Return (rel, data, is_dir) for allowlisted regular files/dirs. Rejects links."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(tar_path, flags)
    except OSError as exc:
        raise Rejected(f"cannot open tar: {exc}") from exc
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Rejected("etc tar must be a regular file")
        if st.st_size > ETC_MAX_TAR_BYTES:
            raise Rejected("etc tar too large")
        proc_path = f"/proc/self/fd/{fd}"
        out: list[tuple[str, bytes, bool]] = []
        files = 0
        with tarfile.open(proc_path, "r:*") as tf:
            for member in tf.getmembers():
                if member.issym() or member.islnk() or member.ischr() or member.isblk() or member.isfifo() or member.issparse():
                    continue
                if not (member.isfile() or member.isdir()):
                    continue
                rel = _tar_name_ok(member.name)
                if rel is None:
                    continue
                if member.isdir():
                    out.append((rel, b"", True))
                    continue
                if member.size < 0 or member.size > ETC_MAX_FILE_BYTES:
                    continue
                files += 1
                if files > ETC_MAX_FILES:
                    raise Rejected("etc tar has too many files")
                extracted = tf.extractfile(member)
                if extracted is None:
                    continue
                data = extracted.read(ETC_MAX_FILE_BYTES + 1)
                if len(data) > ETC_MAX_FILE_BYTES:
                    continue
                out.append((rel, data, False))
        return out
    finally:
        os.close(fd)


def _mkdirat_root(dirfd: int, name: str) -> None:
    try:
        os.mkdir(name, DIR_MODE, dir_fd=dirfd)
    except FileExistsError:
        pass
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dirfd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode):
            raise Rejected(f"{name} is not a directory")
        if stat.S_ISLNK(st.st_mode):
            raise Rejected(f"{name} is a symlink")
        if _euid() == 0:
            os.fchown(fd, 0, 0)
        os.fchmod(fd, DIR_MODE)
    finally:
        os.close(fd)


def _publish_file_at(dirfd: int, name: str, data: bytes) -> None:
    tmp = f".omaclone.{name}.tmp"
    try:
        os.unlink(tmp, dir_fd=dirfd)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, FILE_MODE, dir_fd=dirfd)
    try:
        written = 0
        while written < len(data):
            written += os.write(fd, data[written:])
        if _euid() == 0:
            os.fchown(fd, 0, 0)
        os.fchmod(fd, FILE_MODE)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)


def restore_etc(tar_path: str) -> None:
    _require_root()
    members = extract_etc_members(tar_path)
    etc = _etc_root()
    etcfd = _open_dir(etc)
    try:
        _fstat_reg_or_dir(etcfd, directory=True)
        published = 0
        for rel, data, is_dir in members:
            if not rel:
                continue
            parts = rel.split("/")
            cur = etcfd
            opened: list[int] = []
            try:
                for i, part in enumerate(parts):
                    last = i == len(parts) - 1
                    if last and not is_dir:
                        _publish_file_at(cur, part, data)
                        published += 1
                        print(f"restored {etc.rstrip('/')}/{rel}", file=sys.stderr)
                        break
                    _mkdirat_root(cur, part)
                    nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=cur)
                    opened.append(nxt)
                    cur = nxt
            finally:
                for fd in reversed(opened):
                    os.close(fd)
        if published == 0 and not any(is_dir for _, _, is_dir in members):
            print("no allowlisted /etc files to restore", file=sys.stderr)
    finally:
        os.close(etcfd)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="omaclone-privileged")
    sub = p.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("install-nfs")
    n.add_argument("--uri", required=True)
    n.add_argument("--mountpoint", required=True)
    d = sub.add_parser("install-disk")
    d.add_argument("--uuid", required=True)
    d.add_argument("--mountpoint", required=True)
    d.add_argument("--fstype", default="auto")
    d.add_argument("--uid", type=int, default=None)
    d.add_argument("--gid", type=int, default=None)
    sub.add_parser("uninstall")
    f = sub.add_parser("format-disk")
    f.add_argument("--path", required=True)
    f.add_argument("--majmin", required=True)
    f.add_argument("--bytes", type=int, required=True)
    f.add_argument("--by-id", default="", dest="by_id")
    f.add_argument("--serial", default="")
    f.add_argument("--pkname", default="")
    f.add_argument("--label", default="")
    c = sub.add_parser("check-disk")
    c.add_argument("--path", required=True)
    c.add_argument("--majmin", required=True)
    c.add_argument("--bytes", type=int, required=True)
    c.add_argument("--by-id", default="", dest="by_id")
    c.add_argument("--serial", default="")
    c.add_argument("--pkname", default="")
    r = sub.add_parser("restore-etc")
    r.add_argument("--tar", required=True)
    e = sub.add_parser("extract-etc")
    e.add_argument("--tar", required=True)
    e.add_argument("--dest", required=True)
    pn = sub.add_parser("print-nfs-unit")
    pn.add_argument("--uri", required=True)
    pn.add_argument("--mountpoint", required=True)
    pd = sub.add_parser("print-disk-unit")
    pd.add_argument("--uuid", required=True)
    pd.add_argument("--mountpoint", required=True)
    pd.add_argument("--fstype", default="auto")
    pd.add_argument("--uid", type=int, default=None)
    pd.add_argument("--gid", type=int, default=None)
    return p


def main(argv: list[str]) -> int:
    argv = list(argv)
    if argv and argv[0] == "--":
        argv = argv[1:]
    try:
        args = build_parser().parse_args(argv)
        if args.cmd == "install-nfs":
            install_nfs(args.uri, args.mountpoint)
        elif args.cmd == "install-disk":
            install_disk(args.uuid, args.mountpoint, args.fstype, args.uid, args.gid)
        elif args.cmd == "uninstall":
            uninstall_units()
        elif args.cmd == "format-disk":
            format_disk(args.path, args.majmin, args.bytes, args.by_id, args.serial, args.pkname, args.label)
        elif args.cmd == "check-disk":
            check_disk_identity(args.path, args.majmin, args.bytes, args.by_id, args.serial, args.pkname)
            print("ok")
        elif args.cmd == "restore-etc":
            restore_etc(args.tar)
        elif args.cmd == "extract-etc":
            dest = Path(args.dest)
            dest.mkdir(parents=True, exist_ok=True)
            for rel, data, is_dir in extract_etc_members(args.tar):
                target = dest / "etc" / rel
                if is_dir or rel == "":
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        elif args.cmd == "print-nfs-unit":
            uri = validate_nfs_uri(args.uri)
            mp = validate_mountpoint(args.mountpoint)
            mount, auto = nfs_unit_text(uri, mp)
            sys.stdout.write(mount + "---\n" + auto)
        elif args.cmd == "print-disk-unit":
            uuid = validate_uuid(args.uuid)
            mp = validate_mountpoint(args.mountpoint)
            fstype = validate_fstype(args.fstype)
            sys.stdout.write(disk_unit_text(uuid, mp, fstype, args.uid, args.gid))
        else:
            return 2
        return 0
    except Rejected as exc:
        print(f"omaclone: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"omaclone: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
