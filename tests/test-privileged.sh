#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

priv() { python3 "$ROOT/scripts/privileged.py" "$@"; }

text=$(priv print-nfs-unit --uri "10.10.0.10:/export" --mountpoint /mnt/omaclone)
printf '%s\n' "$text" | grep -q '^What=10.10.0.10:/export$' || fail "nfs unit What"
printf '%s\n' "$text" | grep -q 'nosuid,nodev,noexec' || fail "nfs unit hardening"
printf '%s\n' "$text" | grep -q 'omaclone-managed=1' || fail "nfs unit marker"
priv print-nfs-unit --uri "not-an-nfs-uri" --mountpoint /mnt/omaclone >/dev/null 2>&1 \
  && fail "print-nfs-unit should reject a bad URI"
priv print-nfs-unit --uri "10.10.0.10:/export" --mountpoint /mnt >/dev/null 2>&1 \
  && fail "print-nfs-unit should reject /mnt"
priv print-nfs-unit --uri "10.10.0.10:/export,suid" --mountpoint /mnt/omaclone >/dev/null 2>&1 \
  && fail "print-nfs-unit should reject comma URI"

dtext=$(priv print-disk-unit --uuid 6A73-E22F --mountpoint /mnt/omaclone --fstype exfat --uid 1000 --gid 1000)
printf '%s\n' "$dtext" | grep -q 'What=/dev/disk/by-uuid/6A73-E22F' || fail "disk unit What"
printf '%s\n' "$dtext" | grep -q 'uid=1000,gid=1000' || fail "disk unit uid/gid"
printf '%s\n' "$dtext" | grep -q 'nosuid,nodev,noexec' || fail "disk unit hardening"
priv print-disk-unit --uuid '../../sda1' --mountpoint /mnt/omaclone >/dev/null 2>&1 \
  && fail "disk unit should reject path UUID"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export OMACLONE_PRIVILEGED_TEST=1
export OMACLONE_UNIT_DIR="$work/units"
export OMACLONE_ARTIFACTS="$work/artifacts.json"
mkdir -p "$OMACLONE_UNIT_DIR"
priv install-nfs --uri "10.10.0.10:/export" --mountpoint /mnt/omaclone-test
shopt -s nullglob
units=("$OMACLONE_UNIT_DIR"/*.mount "$OMACLONE_UNIT_DIR"/*.automount)
((${#units[@]} == 2)) || fail "install-nfs should publish mount+automount, got ${#units[@]}"
for u in "${units[@]}"; do
  [[ -f "$u" && ! -L "$u" ]] || fail "unit must be a regular file: $u"
  mode=$(stat -c '%a' "$u")
  [[ "$mode" == 644 ]] || fail "unit mode $mode, want 644"
  grep -q 'omaclone-managed=1' "$u" || fail "published unit missing marker"
done
[[ -f "$OMACLONE_ARTIFACTS" ]] || fail "artifacts file missing"
priv uninstall
shopt -s nullglob
left=("$OMACLONE_UNIT_DIR"/*.mount "$OMACLONE_UNIT_DIR"/*.automount)
((${#left[@]} == 0)) || fail "uninstall left units: ${left[*]}"

# Collision-safe: foreign unit with our name pattern is left if hash mismatches.
priv install-disk --uuid 6A73-E22F --mountpoint /mnt/omaclone-disk --fstype ext4 --uid 1000 --gid 1000
disk_unit=$(ls "$OMACLONE_UNIT_DIR"/*.mount | head -n1)
printf '%s\n' "# not ours anymore" >"$disk_unit"
priv uninstall
[[ -f "$disk_unit" ]] || fail "uninstall must not remove a unit whose hash no longer matches"
rm -f "$disk_unit"

tardir=$(mktemp -d)
mkdir -p "$tardir/etc/fido2"
echo ok >"$tardir/etc/fido2/ok"
python3 - "$tardir" <<'PY'
import io, tarfile, pathlib, sys
root = pathlib.Path(sys.argv[1])
tarpath = root / "etc.tar"
with tarfile.open(tarpath, "w") as tf:
    tf.add(root / "etc/fido2/ok", arcname="etc/fido2/ok")
    info = tarfile.TarInfo("etc/fido2/link")
    info.type = tarfile.SYMTYPE
    info.linkname = "/etc/passwd"
    tf.addfile(info)
    hard = tarfile.TarInfo("etc/fido2/hard")
    hard.type = tarfile.LNKTYPE
    hard.linkname = "etc/fido2/ok"
    tf.addfile(hard)
    slip = tarfile.TarInfo("../omaclone-tar-slip-outside")
    slip.size = 5
    tf.addfile(slip, io.BytesIO(b"pwned"))
    evil = tarfile.TarInfo("etc/../evil")
    evil.size = 4
    tf.addfile(evil, io.BytesIO(b"bad\n"))
    fstab = tarfile.TarInfo("etc/fstab")
    fstab.size = 4
    tf.addfile(fstab, io.BytesIO(b"nope"))
PY
extract=$(mktemp -d)
priv extract-etc --tar "$tardir/etc.tar" --dest "$extract"
[[ -f "$extract/etc/fido2/ok" ]] || fail "allowlisted fido2 file missing"
[[ ! -e "$extract/etc/fido2/link" ]] || fail "symlink member extracted"
[[ ! -e "$extract/etc/fido2/hard" ]] || fail "hardlink member extracted"
[[ ! -e "$extract/evil" ]] || fail "etc/../ member escaped"
[[ ! -e "$extract/etc/fstab" ]] || fail "fstab is not on the closed allowlist"
[[ ! -e "$(dirname "$extract")/omaclone-tar-slip-outside" ]] || fail "tar slip escaped"

etc_root=$(mktemp -d)
export OMACLONE_ETC_ROOT="$etc_root"
priv restore-etc --tar "$tardir/etc.tar"
[[ -f "$etc_root/fido2/ok" ]] || fail "restore-etc did not publish fido2/ok"
mode=$(stat -c '%a' "$etc_root/fido2/ok")
[[ "$mode" == 644 ]] || fail "restored file mode $mode, want 644"
[[ ! -L "$etc_root/fido2/ok" ]] || fail "restored file is a symlink"
rm -rf "$tardir" "$extract" "$etc_root"

echo OK
