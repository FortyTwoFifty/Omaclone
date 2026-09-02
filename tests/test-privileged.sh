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

# Publish must refuse a pre-existing foreign unit of the same name.
foreign_mp=/mnt/omaclone-collide
foreign_unit=$(systemd-escape -p --suffix=mount "$foreign_mp")
cat >"$OMACLONE_UNIT_DIR/$foreign_unit" <<'EOF'
[Unit]
Description=foreign
EOF
set +e
priv install-nfs --uri "10.10.0.10:/export" --mountpoint "$foreign_mp" >/tmp/omaclone-collide.err 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "install-nfs must refuse to replace a foreign unit"
grep -q 'foreign' "$OMACLONE_UNIT_DIR/$foreign_unit" || fail "foreign unit was overwritten"
grep -qi 'refusing to replace' /tmp/omaclone-collide.err || fail "collision should be refused: $(cat /tmp/omaclone-collide.err)"
rm -f "$OMACLONE_UNIT_DIR/$foreign_unit"

priv check-disk --path /dev/null --majmin 1:3 --bytes 1 --by-id "" >/dev/null 2>&1 \
  && fail "check-disk must require by-id"

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

# Member cap: a small tar with too many members must be rejected, not fully materialized.
bomb=$(mktemp)
python3 - "$bomb" <<'PY'
import tarfile, sys, io
path = sys.argv[1]
with tarfile.open(path, "w") as tf:
    for i in range(200):
        info = tarfile.TarInfo(f"etc/fido2/n{i}")
        info.type = tarfile.SYMTYPE
        info.linkname = "x"
        tf.addfile(info)
PY
set +e
priv extract-etc --tar "$bomb" --dest "$(mktemp -d)" >/tmp/omaclone-bomb.err 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "oversized member count should be rejected"
grep -qi 'too many members' /tmp/omaclone-bomb.err || fail "member cap: $(cat /tmp/omaclone-bomb.err)"
rm -f "$bomb"

# run-helper must cap incrementally and kill the producer.
set +e
python3 "$ROOT/scripts/run-helper.py" 64 2 1 -- python3 -c 'import sys,time
while True:
    sys.stdout.write("x"*32)
    sys.stdout.flush()
    time.sleep(0.01)
' >/tmp/omaclone-cap.out 2>/tmp/omaclone-cap.err
rc=$?
set -e
(( rc != 0 )) || fail "run-helper should fail on byte cap"
got=$(wc -c </tmp/omaclone-cap.out)
(( got <= 64 )) || fail "run-helper wrote $got bytes after 64-byte cap"

echo OK
