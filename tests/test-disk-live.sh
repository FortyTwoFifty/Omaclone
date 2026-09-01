#!/usr/bin/env bash
# Opt-in live extra-disk round-trip on a plugged-in USB volume.
# Skips unless OMACLONE_DISK_LIVE=1. Never formats, never touches EFI,
# never deletes user media. Test restic data is removed on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if [[ "${OMACLONE_DISK_LIVE:-}" != 1 ]]; then
  echo "SKIP tests/test-disk-live.sh (set OMACLONE_DISK_LIVE=1 to run)"
  exit 0
fi

need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
need restic
need jq
need python3
need udisksctl
need findmnt
need lsblk

LIVE_UUID="${OMACLONE_DISK_LIVE_UUID:-6A73-E22F}"
LIVE_DEV="${OMACLONE_DISK_LIVE_DEV:-/dev/sdb2}"
MEDIA_A="GraphicAudio Download"
MEDIA_B="TrueNAS Config and Backup"

[[ -e "/dev/disk/by-uuid/$LIVE_UUID" ]] \
  || fail "live disk UUID $LIVE_UUID is not connected"
[[ -b "$LIVE_DEV" ]] || fail "live device missing: $LIVE_DEV"

dev_uuid=$(lsblk -n -o UUID "$LIVE_DEV" | head -n1)
[[ "$dev_uuid" == "$LIVE_UUID" ]] \
  || fail "$LIVE_DEV UUID is $dev_uuid, expected $LIVE_UUID (refusing to continue)"

# Must start unmounted so this matches a just-plugged-in disk.
if findmnt -n -S "/dev/disk/by-uuid/$LIVE_UUID" >/dev/null 2>&1; then
  fail "live disk is already mounted; unmount it first so the test sees a raw plug-in"
fi

# 1. Raw plug-in inventory (drive unmounted)
cand=$(python3 "$ROOT/scripts/disk_candidates.py")
printf '%s\n' "$cand" | grep -q "$LIVE_DEV" \
  || fail "disk_candidates should list $LIVE_DEV while unmounted: $cand"
printf '%s\n' "$cand" | grep -q '/dev/sdb1' \
  && fail "disk_candidates offered EFI /dev/sdb1: $cand"
echo "PASS: unmounted inventory lists $LIVE_DEV, not EFI"

export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env
omaclone_install_dummy_secrets

live_mp=""
test_root=""
omaclone_test_cleanup() {
  set +e
  local mp
  if [[ -e "/dev/disk/by-uuid/$LIVE_UUID" ]] \
      && ! findmnt -n -S "/dev/disk/by-uuid/$LIVE_UUID" >/dev/null 2>&1; then
    udisksctl mount -b "$LIVE_DEV" --no-user-interaction >/dev/null 2>&1
  fi
  mp=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$LIVE_UUID" 2>/dev/null | head -n1)
  if [[ -n "$mp" ]]; then
    if [[ -n "${test_root:-}" && -d "$test_root" ]]; then
      rm -rf "$test_root"
    fi
    # Dummy-password test kit must not stay on the user's volume.
    if [[ -d "$mp/omaclone" ]]; then
      rm -rf "$mp/omaclone"
    fi
    [[ -d "$mp/$MEDIA_A" ]] || echo "WARNING: media missing at cleanup: $MEDIA_A" >&2
    [[ -d "$mp/$MEDIA_B" ]] || echo "WARNING: media missing at cleanup: $MEDIA_B" >&2
    udisksctl unmount -b "$LIVE_DEV" --no-user-interaction >/dev/null 2>&1
  fi
  rm -rf "$OMACLONE_TEST_HOME"
}

assert_media() {
  local mp="$1"
  [[ -d "$mp/$MEDIA_A" ]] || fail "refusing to continue: missing $mp/$MEDIA_A"
  [[ -d "$mp/$MEDIA_B" ]] || fail "refusing to continue: missing $mp/$MEDIA_B"
  [[ ! -e "$mp/repo" ]] || fail "root-level repo/ reappeared at $mp"
}

omaclone_test_cfg transport.backend disk
omaclone_test_cfg transport.uuid "$LIVE_UUID"
omaclone_test_cfg transport.device "$LIVE_DEV"
omaclone_test_cfg transport.fstype exfat
omaclone_test_cfg transport.mountpoint ""
omaclone_test_cfg transport.mode cold
omaclone_test_cfg restic.repo ""
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg secrets.keyring_offer declined
omaclone_test_cfg destination.profile disk
omaclone_test_cfg retention.preset last-5
omaclone_test_cfg locations.ids usb-live
omaclone_test_cfg locations.active usb-live
omaclone_test_cfg locations.usb-live.backend disk
omaclone_test_cfg locations.usb-live.uuid "$LIVE_UUID"
omaclone_test_cfg locations.usb-live.device "$LIVE_DEV"
omaclone_test_cfg locations.usb-live.fstype exfat
omaclone_test_cfg locations.usb-live.mountpoint ""
omaclone_test_cfg locations.usb-live.mode cold
omaclone_test_cfg locations.usb-live.schedule on
omaclone_test_cfg locations.usb-live.label "Live MP510"
omaclone_test_cfg locations.usb-live.profile disk
omaclone_test_cfg locations.usb-live.repo ""

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/backend.sh"
# lib.sh installs its own EXIT trap; keep disk cleanup last.
trap 'omaclone_test_cleanup' EXIT INT TERM HUP

# 2. Cold mount via the disk transport (udisks, no sudo)
nas_backup_backend_run transport disk ready \
  && fail "ready should be false while unmounted"
nas_backup_backend_run transport disk mount \
  || fail "disk mount (udisks) failed"
nas_backup_backend_run transport disk ready \
  || fail "ready should be true after mount"

live_mp=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$LIVE_UUID" | head -n1)
[[ -n "$live_mp" ]] || fail "disk mounted but findmnt has no TARGET"
[[ "$live_mp" == /run/media/* ]] \
  || fail "expected udisks mount under /run/media, got $live_mp"
assert_media "$live_mp"

got_repo=$(python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get restic.repo)
[[ "$got_repo" == "$live_mp/omaclone/repo" ]] \
  || fail "bind repo should be $live_mp/omaclone/repo, got $got_repo"
[[ -d "$live_mp/omaclone/repo" ]] || fail "mount should create $live_mp/omaclone/repo"

# Writable as the user, no sudo
probe="$live_mp/omaclone/.omaclone-live-write-test.$$"
if ! ( umask 077; : >"$probe" ) 2>/dev/null; then
  fail "udisks mount is not writable as uid $(id -u) at $live_mp/omaclone"
fi
rm -f "$probe"
echo "PASS: cold udisks mount at $live_mp, kit $got_repo, user-writable"

# 3. Tiny restic round-trip in the product kit path, then delete the kit
mkdir -p "$HOME/identity" "$HOME/.config/omaclone-app"
printf 'hello-from-disk-live\n' >"$HOME/identity/marker.txt"
printf 'dotfile\n' >"$HOME/.config/omaclone-app/settings"

omaclone_test_cfg restic.repo "$got_repo"
omaclone_test_cfg locations.usb-live.repo "$got_repo"
omaclone_test_cfg locations.usb-live.mountpoint "$live_mp"

export OMACLONE_SKIP_BOOTSTRAP=1
if [[ -f "$got_repo/config" ]]; then
  echo "PASS: restic repo already initialized at $got_repo"
else
  omaclone_cli init
fi
# Cold mode unmounts after restic; remount checks happen on the next clone.
if findmnt -n -S "/dev/disk/by-uuid/$LIVE_UUID" >/dev/null 2>&1; then
  nas_backup_backend_run transport disk unmount 2>/dev/null || true
fi
echo "PASS: restic init (cold)"

omaclone_cli clone --cron >/tmp/omaclone-disk-live-clone.$$ 2>&1 \
  || { cat /tmp/omaclone-disk-live-clone.$$; fail "clone --cron failed"; }
rm -f /tmp/omaclone-disk-live-clone.$$
[[ "$(omaclone_last_result status)" == ok ]] \
  || fail "clone did not write last-result ok: $(omaclone_last_result status) $(omaclone_last_result message)"
echo "PASS: clone --cron while plugged in"

# 4. Cold unmount after post-restic
if findmnt -n -S "/dev/disk/by-uuid/$LIVE_UUID" >/dev/null 2>&1; then
  fail "cold post-restic should have unmounted the disk"
fi
nas_backup_backend_run transport disk ready \
  && fail "ready should be false after cold unmount"
[[ -e "/dev/disk/by-uuid/$LIVE_UUID" ]] \
  || fail "UUID node disappeared after unmount (disk was unplugged?)"
echo "PASS: cold unmount; UUID still connected"

# 5. Cron while unmounted-but-plugged remounts, clones, unmounts
omaclone_cli clone --cron >/tmp/omaclone-disk-live-clone2.$$ 2>&1 \
  || { cat /tmp/omaclone-disk-live-clone2.$$; fail "second clone --cron (from unmounted) failed"; }
rm -f /tmp/omaclone-disk-live-clone2.$$
[[ "$(omaclone_last_result status)" == ok ]] \
  || fail "second clone: $(omaclone_last_result status) $(omaclone_last_result message)"
if findmnt -n -S "/dev/disk/by-uuid/$LIVE_UUID" >/dev/null 2>&1; then
  fail "second cold clone should unmount afterwards"
fi
echo "PASS: cron from unmounted-but-plugged remounted and unmounted"

# 6. Discover + location list while remounted
nas_backup_backend_run transport disk mount || fail "remount for discover failed"
live_mp=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$LIVE_UUID" | head -n1)
assert_media "$live_mp"
# Minimal kit markers so discover accepts <mount>/omaclone
touch "$live_mp/omaclone/.omaclone-bootstrap"
[[ -f "$live_mp/omaclone/repo/config" ]] || fail "kit repo/config missing after clones"

unset OMACLONE_SKIP_DISCOVER
disc=$(python3 "$ROOT/scripts/discover_bootstrap.py")
printf '%s\n' "$disc" | grep -q "$live_mp/omaclone" \
  || fail "discover should find $live_mp/omaclone: $disc"
printf '%s\n' "$disc" | grep -q "$MEDIA_A" \
  && fail "discover listed media folder: $disc"
echo "PASS: discover finds omaclone/ kit only"

json=$(omaclone_cli location list --json)
echo "$json" | jq -e --arg id usb-live '.[] | select(.id==$id and .connected==true)' >/dev/null \
  || fail "location list missing connected usb-live: $json"
echo "$json" | jq -e --arg id usb-live '.[] | select(.id==$id) | .snapshotCount >= 1' >/dev/null \
  || fail "location list snapshotCount: $json"
echo "PASS: location list connected with snapshot count"

# Restore check (still mounted)
pwfile=$(mktemp)
printf '%s' "dummy-password-not-for-real-repos" >"$pwfile"
n=$(restic --password-file "$pwfile" --repo "$got_repo" snapshots --json | jq 'length')
[[ "$n" -ge 2 ]] || fail "expected at least 2 snapshots after two clones, got $n"
sid=$(restic --password-file "$pwfile" --repo "$got_repo" snapshots --json | jq -r '.[0].short_id')
rm -f "$HOME/identity/marker.txt" "$HOME/.config/omaclone-app/settings"
omaclone_cli restore --snapshot "$sid" --blank-omarchy >/tmp/omaclone-disk-live-restore.$$ 2>&1 \
  || { cat /tmp/omaclone-disk-live-restore.$$; fail "restore --snapshot failed"; }
rm -f /tmp/omaclone-disk-live-restore.$$
got=$(cat "$HOME/identity/marker.txt")
[[ "$got" == "hello-from-disk-live" ]] || fail "restored marker mismatch: $got"
rm -f "$pwfile"
echo "PASS: restore round-trip"

# 7. Cron skip when UUID is missing
omaclone_test_cfg transport.uuid "DEAD-BEEF-NOT-A-DISK"
omaclone_test_cfg locations.usb-live.uuid "DEAD-BEEF-NOT-A-DISK"
rm -f "$NAS_BACKUP_STATE_DIR"/last-result*.json
set +e
omaclone_cli clone --cron >/tmp/omaclone-disk-live-skip.$$ 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "missing UUID --cron should exit 0: $(cat /tmp/omaclone-disk-live-skip.$$)"
[[ "$(omaclone_last_result status)" == skip ]] \
  || fail "missing UUID: expected skip, got $(omaclone_last_result status)"
printf '%s\n' "$(omaclone_last_result message)" | grep -qi "not connected" \
  || fail "missing UUID message: $(omaclone_last_result message)"
rm -f /tmp/omaclone-disk-live-skip.$$
echo "PASS: cron skip when UUID missing"

# Restore live UUID so cleanup can unmount
omaclone_test_cfg transport.uuid "$LIVE_UUID"
omaclone_test_cfg locations.usb-live.uuid "$LIVE_UUID"

if findmnt -n -S /dev/sdb1 >/dev/null 2>&1; then
  fail "test mounted EFI /dev/sdb1"
fi
nas_backup_backend_run transport disk mount || fail "remount for final media check failed"
live_mp=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$LIVE_UUID" | head -n1 || true)
assert_media "$live_mp"
echo "PASS: user media intact; EFI never mounted"

echo OK
