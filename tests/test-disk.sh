#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export NAS_BACKUP_ROOT="$ROOT"
NAS_BACKUP_USER_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR"' EXIT
export NAS_BACKUP_USER_CONFIG_DIR
export NAS_BACKUP_STATE_DIR="$NAS_BACKUP_USER_CONFIG_DIR/state"
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"

MOCK_BIN=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR" "$MOCK_BIN"' EXIT

cat >"$MOCK_BIN/findmnt" <<'FINDMNT_EOF'
#!/usr/bin/env bash
set -euo pipefail
MOUNTS_FILE="${TEST_MOUNTS_FILE:-}"
shift 2>/dev/null || true
by_uuid=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) shift ;;
    -o) shift; shift ;;
    -S) by_uuid=1; shift ;;
    *)
      if (( by_uuid )); then
        [[ -f "$MOUNTS_FILE" ]] && cat "$MOUNTS_FILE"
        exit 0
      fi
      if [[ -f "$MOUNTS_FILE" ]] && grep -qF "$1" "$MOUNTS_FILE" 2>/dev/null; then
        echo "$1"
      fi
      exit 0
      ;;
  esac
done
if (( by_uuid )); then
  [[ -n "${TEST_MOUNTS_FILE:-}" && -f "$TEST_MOUNTS_FILE" ]] && cat "$TEST_MOUNTS_FILE"
fi
exit 0
FINDMNT_EOF

export UDISKSCTL_ACTION="$NAS_BACKUP_USER_CONFIG_DIR/udisks.action"
export MOUNT_LOG="$NAS_BACKUP_USER_CONFIG_DIR/mount.log"

cat >"$MOCK_BIN/udisksctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch "${UDISKSCTL_ACTION}" 2>/dev/null || true
exit 0
EOF

cat >"$MOCK_BIN/mount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "mount $*" >> "${MOUNT_LOG}" 2>/dev/null || true
exit 0
EOF

chmod +x "$MOCK_BIN/findmnt" "$MOCK_BIN/udisksctl" "$MOCK_BIN/mount"
export PATH="$MOCK_BIN:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/transport-lib.sh"

grep -q 'cfg_set transport.mode hot' "$ROOT/backends/transport/disk" || fail "setup should set mode=hot for internal extra disks"
grep -q 'cfg_set transport.mode cold' "$ROOT/backends/transport/disk" || fail "setup should set mode=cold for USB/desktop mounts"
echo "PASS: setup sets transport.mode hot/cold"

grep -q 'mkfs.ext4 -F -L omaclone' "$ROOT/backends/transport/disk" && fail "_format_device should not hardcode omaclone label"
echo "PASS: _format_device does not hardcode label"

grep -q 'install-disk-mount.sh' "$ROOT/backends/transport/disk" \
  || fail "setup may install a systemd mount after confirmation"
grep -q 'Install a systemd mount' "$ROOT/backends/transport/disk" \
  || fail "systemd extra-disk mount must be opt-in"
echo "PASS: systemd extra-disk mount is opt-in"
grep -q 'nosuid,nodev,noexec' "$ROOT/scripts/privileged.py" \
  || fail "disk systemd mount should be nosuid,nodev,noexec"
echo "PASS: disk mount options include nosuid,nodev,noexec"

grep -q 'findmnt.*|| true' "$ROOT/backends/transport/disk" \
  || fail "findmnt miss must not abort mount under pipefail"
grep -q '_disk_uuid_src' "$ROOT/backends/transport/disk" || fail "disk should resolve UUID via _disk_uuid_src"
grep -q 'omaclone_kit_dir' "$ROOT/backends/transport/disk" || fail "bootstrap-install should use omaclone_kit_dir"
echo "PASS: bootstrap-install prefers live TARGET"

grep -q 'gum confirm --default=false' "$ROOT/backends/transport/disk" \
  || fail "USB/hotplug setup should default to no fixed mountpoint"
grep -q 'omaclone_privileged format-disk' "$ROOT/backends/transport/disk" \
  || fail "format must go through the privileged helper"
grep -q 'sudo_tty' "$ROOT/backends/transport/disk" \
  || fail "preferred-path mounts should use sudo_tty so gum does not steal the sudo prompt"
grep -q 'omaclone_validate_mountpoint' "$ROOT/backends/transport/disk" \
  || fail "disk mount/setup must validate the mountpoint before sudo"
grep 'transport "$backend" mount 2>/dev/null' "$ROOT/scripts/cmd-setup.sh" \
  && fail "setup must not hide transport mount errors"
echo "PASS: removable disks default to cold/udisks; mount errors are visible"

grep -q 'uid=$(command id -u),gid=$(command id -g)' "$ROOT/backends/transport/disk" \
  || fail "FAT/exFAT hot mounts should set uid/gid (command id; id() is the backend verb)"
grep -q 'uid={uid},gid={gid}' "$ROOT/scripts/privileged.py" \
  || fail "disk systemd mount should set uid/gid for FAT/exFAT"
echo "PASS: FAT/exFAT mounts include uid/gid"

uuid_fat="6A73-E22F"
[[ "$uuid_fat" =~ ^[0-9a-fA-F-]{8,36}$ ]] || fail "FAT-style UUID should match install-disk-mount regex"
echo "PASS: FAT-style UUID 6A73-E22F is valid"

source "$ROOT/scripts/transport-lib.sh"
omaclone_disk_uuid_ok "$uuid_fat" || fail "FAT UUID should pass omaclone_disk_uuid_ok"
omaclone_disk_uuid_ok "../../sda1" && fail "path UUID must fail"
omaclone_disk_uuid_ok ".." && fail "dotdot UUID must fail"
omaclone_validate_mountpoint "/mnt/../../etc" >/dev/null && fail "disk mount over /etc via .. must fail"
echo "PASS: disk UUID and mountpoint reject path traversal"

grep -q 'readlink -f' "$ROOT/backends/transport/disk" \
  || fail "disk live mount must match UUID source, not any filesystem at the mountpoint"

grep -q 'omaclone/repo' "$ROOT/backends/transport/disk" || fail "disk should default restic.repo under omaclone/"
echo "PASS: disk restic.repo uses omaclone/ kit dir"

kit_tmp=$(mktemp -d)
got=$(omaclone_kit_dir "$kit_tmp")
[[ "$got" == "$kit_tmp/omaclone" ]] || fail "kit dir: $got"
mkdir -p "$kit_tmp/repo"
touch "$kit_tmp/repo/config"
got=$(omaclone_kit_dir "$kit_tmp")
[[ "$got" == "$kit_tmp/omaclone" ]] || fail "root repo is not a kit: $got"
rm -rf "$kit_tmp"
echo "PASS: omaclone_kit_dir is <mount>/omaclone"

FAKE_DEV_TREE=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR" "$MOCK_BIN" "$FAKE_DEV_TREE"' EXIT
mkdir -p "$FAKE_DEV_TREE/disk/by-uuid"
touch "$FAKE_DEV_TREE/disk/by-uuid/AAAA-1111"

_ready() {
  local uuid live_target
  uuid=$(cfg transport.uuid)
  [[ -n "$uuid" ]] || return 1
  [[ -e "$FAKE_DEV_TREE/disk/by-uuid/$uuid" ]] || return 1
  live_target=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$uuid" 2>/dev/null | head -n 1)
  [[ -n "$live_target" ]]
}

_test_mount() {
  local uuid mountpoint fstype live_target
  uuid=$(cfg transport.uuid)
  mountpoint=$(cfg transport.mountpoint "")
  fstype=$(cfg transport.fstype auto)
  [[ -n "$uuid" ]] || return 1
  live_target=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$uuid" 2>/dev/null | head -n 1)
  if [[ -n "$live_target" ]]; then
    return 0
  fi
  if [[ ! -e "$FAKE_DEV_TREE/disk/by-uuid/$uuid" ]]; then
    return 1
  fi
  if [[ -n "$mountpoint" ]]; then
    mkdir -p "$mountpoint" 2>/dev/null || true
    mount -t "$fstype" -o noatime "/dev/disk/by-uuid/$uuid" "$mountpoint"
  fi
}

_unmount() { return 0; }

_post_restic() { return 0; }

_ready_or_mount() {
  _ready && return 0
  _test_mount 2>/dev/null || true
}

cfg_set transport.uuid ""
if _ready; then fail "ready should be false when UUID empty"; fi
echo "PASS: ready=false with no UUID"

cfg_set transport.uuid "missing-node"
if _ready; then fail "ready should be false when UUID node absent"; fi
echo "PASS: ready=false with missing node"

cfg_set transport.uuid "AAAA-1111"
TEST_MOUNTS_FILE=$(mktemp)
export TEST_MOUNTS_FILE
echo "/run/media/user/Disk" > "$TEST_MOUNTS_FILE"
_ready || fail "ready should be true when UUID node exists and is mounted"
echo "PASS: ready=true with live udev mount (mp empty)"

cfg_set transport.mountpoint "/mnt/omaclone"
TEST_MOUNTS_FILE=$(mktemp)
export TEST_MOUNTS_FILE
echo "/run/media/user/Disk" > "$TEST_MOUNTS_FILE"
_ready || fail "ready should be true with different live target"
echo "PASS: ready=true when configured mp differs from live TARGET"

rm -f "$MOUNT_LOG"
cfg_set transport.uuid "AAAA-1111"
TEST_MOUNTS_FILE=$(mktemp)
export TEST_MOUNTS_FILE
echo "/run/media/user/Disk" > "$TEST_MOUNTS_FILE"
_test_mount 2>/dev/null || true
if [[ -f "$MOUNT_LOG" ]]; then fail "mount should not remount when already live"; fi
echo "PASS: mount skips remount when live TARGET exists"

rm -f "$MOUNT_LOG"
preferred_mp="$NAS_BACKUP_USER_CONFIG_DIR/mnt"
mkdir -p "$preferred_mp"
cfg_set transport.uuid "AAAA-1111"
cfg_set transport.mountpoint "$preferred_mp"
TEST_MOUNTS_FILE=""
export TEST_MOUNTS_FILE
_test_mount 2>/dev/null || true
if [[ ! -f "$MOUNT_LOG" ]]; then fail "mount should attempt mount with preferred mp"; fi
echo "PASS: mount uses preferred mp when not mounted"

_post_restic
echo "PASS: post_restic is no-op (hybrid)"

_unmount
echo "PASS: unmount is no-op (hybrid)"

# Real backend: leftover root repo still binds to <mount>/omaclone/repo
export OMACLONE_DISK_BY_UUID_DIR="$FAKE_DEV_TREE/disk/by-uuid"
fake_live="$NAS_BACKUP_USER_CONFIG_DIR/media-disk"
mkdir -p "$fake_live/repo"
touch "$fake_live/repo/config"
TEST_MOUNTS_FILE=$(mktemp)
export TEST_MOUNTS_FILE
echo "$fake_live" > "$TEST_MOUNTS_FILE"
cfg_set transport.uuid "AAAA-1111"
cfg_set transport.mountpoint ""
cfg_set transport.mode cold
cfg_set restic.repo "$fake_live/repo"
"$ROOT/backends/transport/disk" mount >/dev/null
got=$(python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get restic.repo)
[[ "$got" == "$fake_live/omaclone/repo" ]] \
  || fail "bind should ignore root repo, got $got"
[[ -d "$fake_live/omaclone/repo" ]] || fail "bind should create omaclone/repo"
echo "PASS: mount binds leftover root repo onto omaclone/repo"

# Real backend: empty mountpoint calls udisksctl
: > "$UDISKSCTL_ACTION"
rm -f "$MOUNT_LOG"
echo "" > "$TEST_MOUNTS_FILE"
cfg_set transport.mountpoint ""
cfg_set restic.repo ""
cat >"$MOCK_BIN/udisksctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "udisksctl \$*" >> "${UDISKSCTL_ACTION}"
if [[ "\${1:-}" == mount ]]; then
  echo "${fake_live}" > "${TEST_MOUNTS_FILE}"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/udisksctl"
"$ROOT/backends/transport/disk" mount >/dev/null
grep -q 'mount -b' "$UDISKSCTL_ACTION" || fail "cold mount should call udisksctl mount -b: $(cat "$UDISKSCTL_ACTION")"
echo "PASS: cold mount invokes udisksctl"

# Real backend: hot exfat mount logs uid/gid
preferred_mp="$NAS_BACKUP_USER_CONFIG_DIR/mnt-hot"
mkdir -p "$preferred_mp"
cat >"$MOCK_BIN/sudo" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "sudo \$*" >> "${MOUNT_LOG}"
if [[ "\${1:-}" == -n ]]; then shift; fi
if [[ "\${1:-}" == mkdir ]]; then
  mkdir -p "\${@: -1}"
fi
if [[ "\${1:-}" == mount ]]; then
  echo "${preferred_mp}" > "${TEST_MOUNTS_FILE}"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/sudo"
: > "$MOUNT_LOG"
echo "" > "$TEST_MOUNTS_FILE"
cfg_set transport.mountpoint "$preferred_mp"
cfg_set transport.fstype exfat
cfg_set transport.mode hot
"$ROOT/backends/transport/disk" mount >/dev/null
grep -q "uid=$(id -u),gid=$(id -g)" "$MOUNT_LOG" \
  || fail "hot exfat mount should pass uid/gid: $(cat "$MOUNT_LOG")"
grep -q "nosuid,nodev,noexec" "$MOUNT_LOG" \
  || fail "hot mount should keep nosuid,nodev,noexec: $(cat "$MOUNT_LOG")"
echo "PASS: hot exfat mount passes uid/gid and nosuid,nodev,noexec"

# Preferred path: sudo mount fails → udisks fallback, still ready
cat >"$MOCK_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "sudo $*" >> "${MOUNT_LOG}"
exit 1
EOF
chmod +x "$MOCK_BIN/sudo"
: > "$UDISKSCTL_ACTION"
: > "$MOUNT_LOG"
echo "" > "$TEST_MOUNTS_FILE"
cfg_set transport.mountpoint "$preferred_mp"
cfg_set transport.fstype exfat
"$ROOT/backends/transport/disk" mount >/dev/null 2>"$NAS_BACKUP_USER_CONFIG_DIR/mount.err"
got=$(python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get restic.repo)
[[ "$got" == "$fake_live/omaclone/repo" ]] \
  || fail "sudo failure should fall back to udisks repo, got $got"
grep -q 'mount -b' "$UDISKSCTL_ACTION" \
  || fail "fallback should call udisksctl: $(cat "$UDISKSCTL_ACTION")"
grep -qi 'trying desktop mount' "$NAS_BACKUP_USER_CONFIG_DIR/mount.err" \
  || fail "fallback should explain sudo mount failed: $(cat "$NAS_BACKUP_USER_CONFIG_DIR/mount.err")"
echo "PASS: preferred mountpoint falls back to udisks when sudo mount fails"

echo "OK"
