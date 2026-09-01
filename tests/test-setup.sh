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
