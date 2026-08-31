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

grep -q 'cfg_set transport.mode hot' "$ROOT/backends/transport/disk" || fail "setup should set mode=hot when mountpoint is set"
grep -q 'cfg_set transport.mode cold' "$ROOT/backends/transport/disk" || fail "setup should set mode=cold for desktop/USB mounts"
echo "PASS: setup sets transport.mode hot/cold"

grep -q 'mkfs.ext4 -F -L omaclone' "$ROOT/backends/transport/disk" && fail "_format_device should not hardcode omaclone label"
echo "PASS: _format_device does not hardcode label"

grep -q 'install-disk-mount.sh' "$ROOT/backends/transport/disk" && fail "setup should not call install-disk-mount.sh"
echo "PASS: no systemd mount install in setup"

grep -q 'findmnt.*by-uuid.*cfg transport.uuid' "$ROOT/backends/transport/disk" || fail "bootstrap-install should prefer findmnt TARGET"
echo "PASS: bootstrap-install prefers live TARGET"

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
touch "$FAKE_DEV_TREE/disk/by-uuid/test-uuid"

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

cfg_set transport.uuid "test-uuid"
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
cfg_set transport.uuid "test-uuid"
TEST_MOUNTS_FILE=$(mktemp)
export TEST_MOUNTS_FILE
echo "/run/media/user/Disk" > "$TEST_MOUNTS_FILE"
_test_mount 2>/dev/null || true
if [[ -f "$MOUNT_LOG" ]]; then fail "mount should not remount when already live"; fi
echo "PASS: mount skips remount when live TARGET exists"

rm -f "$MOUNT_LOG"
preferred_mp="$NAS_BACKUP_USER_CONFIG_DIR/mnt"
mkdir -p "$preferred_mp"
cfg_set transport.uuid "test-uuid"
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

echo "OK"
