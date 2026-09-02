#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/locations.sh"

# location_save_current refuses an empty id
set +e
out=$(location_save_current "" 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "location_save_current empty id should fail"
printf '%s\n' "$out" | grep -qi "empty" || fail "empty id error should mention empty: $out"

# disk schedule: cold/USB off, hot on
[[ "$(location_default_schedule disk cold)" == off ]] || fail "cold disk should default off"
[[ "$(location_default_schedule disk)" == off ]] || fail "disk without mode should default off"
[[ "$(location_default_schedule disk hot)" == on ]] || fail "hot disk should default on"
[[ "$(location_default_schedule nfs)" == on ]] || fail "nfs should default on"
[[ "$(location_default_label disk disk cold)" == USB ]] || fail "cold disk label"
[[ "$(location_default_label nfs nas)" == NAS ]] || fail "nfs label"
[[ "$(location_default_label s3)" == "Cloud (S3)" ]] || fail "s3 default label: $(location_default_label s3)"
[[ "$(location_default_label s3 cloud "" aws)" == "AWS S3" ]] || fail "aws s3 label: $(location_default_label s3 cloud "" aws)"
[[ "$(location_default_label s3 cloud "" r2)" == "Cloudflare R2" ]] || fail "r2 label"

[[ "$(location_label_from_mount "/run/media/me/Omaclone/omaclone" disk cold)" == USB ]] \
  || fail "kit on a volume labeled Omaclone should name USB, got $(location_label_from_mount "/run/media/me/Omaclone/omaclone" disk cold)"
[[ "$(location_label_from_mount "/run/media/me/Kingston/omaclone" disk cold)" == Kingston ]] \
  || fail "volume label Kingston should be kept"
[[ "$(location_import_label "/run/media/me/Omaclone/omaclone" "Discovered Omaclone" disk cold)" == USB ]] \
  || fail "Discovered Omaclone should be replaced, got $(location_import_label "/run/media/me/Omaclone/omaclone" "Discovered Omaclone" disk cold)"
[[ "$(location_import_label "/mnt/x" "Travel stick" disk cold)" == "Travel stick" ]] \
  || fail "custom label must be kept"
location_expected_offline "" && fail "empty id is not expected-offline"
omaclone_test_cfg locations.usb.backend disk
omaclone_test_cfg locations.usb.mode cold
location_expected_offline usb || fail "cold disk should be expected-offline"
omaclone_test_cfg locations.nvme.backend disk
omaclone_test_cfg locations.nvme.mode hot
location_expected_offline nvme && fail "hot extra disk should not be expected-offline"

omaclone_test_cfg transport.backend local
omaclone_test_cfg restic.repo "$HOME/repo"
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg destination.profile local
mkdir -p "$HOME/repo"
location_save_current local "Local" off
config_set locations.active local

# CLI schedule
got=$(omaclone_cli location schedule)
[[ "$got" == off ]] || fail "schedule show expected off, got $got"
omaclone_cli location schedule on >/dev/null
got=$(omaclone_cli location schedule)
[[ "$got" == on ]] || fail "schedule on did not stick, got $got"
omaclone_cli location schedule local off >/dev/null
got=$(omaclone_cli location schedule local)
[[ "$got" == off ]] || fail "schedule local off, got $got"

# S3 last-result ok is not proof of init
omaclone_test_cfg transport.backend s3
omaclone_test_cfg restic.repo "s3:https://example.invalid/bucket"
omaclone_test_cfg restic.initialized ""
printf '%s\n' '{"status":"ok","unix":1}' >"$NAS_BACKUP_STATE_DIR/last-result.json"
if repo_initialized; then
  fail "s3 last-result ok must not make repo_initialized true"
fi
omaclone_test_cfg restic.initialized 1
repo_initialized || fail "restic.initialized=1 should count"

# start over clears destination/secrets/locations, not the restic data dir
fake_repo="$HOME/on-disk-repo"
mkdir -p "$fake_repo"
echo keep >"$fake_repo/config"
omaclone_test_cfg transport.backend local
omaclone_test_cfg restic.repo "$fake_repo"
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg restic.initialized 1
omaclone_test_cfg locations.ids local
setup_start_over
[[ -z "$(config_get transport.backend)" ]] || fail "start over left transport.backend"
[[ -z "$(config_get secrets.backend)" ]] || fail "start over left secrets.backend"
[[ -z "$(config_get restic.initialized)" ]] || fail "start over left restic.initialized"
[[ -z "$(config_get locations.ids)" ]] || fail "start over left locations.ids"
[[ -z "$(config_get locations.local.backend)" ]] || fail "start over left locations.local"
[[ -f "$fake_repo/config" ]] || fail "start over deleted the restic repo on disk"
[[ "$(cat "$fake_repo/config")" == keep ]] || fail "start over mutated the restic repo"

grep -q 'setup_confirm_erase_all' "$ROOT/scripts/cmd-setup.sh" \
  || fail "setup wizard must confirm before erasing all settings"
grep -q 'ERASE SETTINGS' "$ROOT/scripts/lib.sh" \
  || fail "erase-all must require typing ERASE SETTINGS"
grep -q 'Abandon this destination' "$ROOT/scripts/cmd-setup.sh" \
  || fail "unfinished setup should abandon one destination, not wipe everything"

# abandon current USB keeps NAS + secrets
omaclone_test_cfg transport.backend disk
omaclone_test_cfg transport.mode cold
omaclone_test_cfg transport.uuid "USB-UUID-NOPE"
omaclone_test_cfg restic.repo "/mnt/missing-usb/omaclone/repo"
omaclone_test_cfg restic.initialized 1
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg locations.ids "nas,usb"
omaclone_test_cfg locations.active usb
omaclone_test_cfg locations.usb.backend disk
omaclone_test_cfg locations.usb.mode cold
omaclone_test_cfg locations.usb.uuid "USB-UUID-NOPE"
omaclone_test_cfg locations.usb.repo "/mnt/missing-usb/omaclone/repo"
omaclone_test_cfg locations.usb.label "Discovered Omaclone"
omaclone_test_cfg locations.nas.backend nfs
omaclone_test_cfg locations.nas.uri "10.10.0.5:/backup"
omaclone_test_cfg locations.nas.mountpoint "/mnt/omaclone-not-here"
omaclone_test_cfg locations.nas.repo "/mnt/omaclone-not-here/omaclone/repo"
omaclone_test_cfg locations.nas.label NAS
migrate_locations
[[ "$(location_get usb label)" == USB ]] || fail "Discovered Omaclone should relabel to USB, got $(location_get usb label)"
if setup_is_unfinished; then
  fail "unplugged USB with a saved NAS must not look like unfinished setup"
fi
setup_abandon_destination
[[ "$(config_get secrets.backend)" == dummy ]] || fail "abandon destination cleared secrets"
[[ "$(config_get locations.active)" == nas ]] || fail "abandon should keep NAS active, got $(config_get locations.active)"
echo ",$(config_get locations.ids)," | grep -q ',usb,' && fail "abandon left usb in ids"
echo ",$(config_get locations.ids)," | grep -q ',nas,' || fail "abandon dropped NAS"
[[ "$(config_get transport.backend)" == nfs ]] || fail "abandon should switch transport to NAS"

# forgetting the last location must not leave setup unfinished
omaclone_test_cfg transport.backend disk
omaclone_test_cfg restic.repo "/mnt/missing-usb/omaclone/repo"
omaclone_test_cfg restic.initialized 1
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg locations.ids usb
omaclone_test_cfg locations.active usb
omaclone_test_cfg locations.usb.backend disk
omaclone_test_cfg locations.usb.mode cold
omaclone_test_cfg locations.usb.uuid "USB-UUID-NOPE"
omaclone_test_cfg locations.usb.repo "/mnt/missing-usb/omaclone/repo"
location_drop usb
[[ -z "$(config_get transport.backend)" ]] || fail "drop last left transport.backend"
[[ -z "$(config_get restic.repo)" ]] || fail "drop last left restic.repo"
[[ "$(config_get secrets.backend)" == dummy ]] || fail "drop last cleared secrets"
if setup_is_unfinished; then
  fail "forgetting the last location must not leave setup unfinished"
fi

omaclone_test_cfg transport.backend s3
omaclone_test_cfg destination.profile cloud
omaclone_test_cfg transport.endpoint example.r2.cloudflarestorage.com
omaclone_test_cfg transport.bucket mybucket
omaclone_test_cfg restic.repo "s3:https://example.r2.cloudflarestorage.com/mybucket/omaclone"
est=$(clone_estimate_text)
[[ -n "$est" ]] || fail "clone_estimate_text empty"

ver=$("$ROOT/scripts/omaclone" --version)
[[ "$ver" == "1.5.0" ]] || fail "omaclone --version expected 1.5.0, got $ver"

card=$(write_recovery_card)
grep -q "plugin add" "$card" || fail "s3 recovery card should use plugin add"
grep -q "/path/to/clone/restore" "$card" && fail "s3 recovery card must not use USB restore path"
grep -qi "s3 / cloud" "$card" || fail "s3 recovery card should mention cloud"

echo OK
