#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env

omaclone_install_dummy_secrets
omaclone_install_user_backend secrets locked "$ROOT/tests/backends/secrets/locked"
omaclone_install_user_backend transport not-ready "$ROOT/tests/backends/transport/not-ready"

repo_parent="$HOME/clone-store"
repo="$repo_parent/omaclone/repo"
mkdir -p "$(dirname "$repo")"

base_location() {
  omaclone_test_cfg destination.profile local
  omaclone_test_cfg retention.preset last-5
  omaclone_test_cfg locations.ids loc
  omaclone_test_cfg locations.active loc
  omaclone_test_cfg locations.loc.label Loc
  omaclone_test_cfg locations.loc.profile local
}

# 1. schedule=off — skip before transport
omaclone_test_cfg transport.backend local
omaclone_test_cfg transport.mountpoint "$repo_parent"
omaclone_test_cfg restic.repo "$repo"
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg secrets.keyring_offer declined
base_location
omaclone_test_cfg locations.loc.backend local
omaclone_test_cfg locations.loc.repo "$repo"
omaclone_test_cfg locations.loc.mountpoint "$repo_parent"
omaclone_test_cfg locations.loc.schedule off

set +e
omaclone_cli clone --cron >/tmp/omaclone-cron-out.$$ 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "schedule=off should exit 0, got $rc: $(cat /tmp/omaclone-cron-out.$$)"
[[ "$(omaclone_last_result status)" == skip ]] || fail "schedule=off: expected skip, got $(omaclone_last_result status)"
msg=$(omaclone_last_result message)
printf '%s\n' "$msg" | grep -qi "not scheduled\|automatic clones are off" \
  || fail "schedule=off: unexpected message: $msg"

# 2. prompt backend cannot run unattended
omaclone_test_cfg locations.loc.schedule on
omaclone_test_cfg secrets.backend prompt
rm -f "$NAS_BACKUP_STATE_DIR"/last-result*.json
set +e
omaclone_cli clone --cron >/tmp/omaclone-cron-out.$$ 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "prompt --cron should exit 0, got $rc: $(cat /tmp/omaclone-cron-out.$$)"
[[ "$(omaclone_last_result status)" == skip ]] || fail "prompt: expected skip, got $(omaclone_last_result status)"
[[ "$(omaclone_last_result reason)" == password ]] || fail "prompt: expected reason=password, got $(omaclone_last_result reason)"
printf '%s\n' "$(omaclone_last_result message)" | grep -qi "prompt" \
  || fail "prompt: message should mention prompt: $(omaclone_last_result message)"

# 3. locked secrets backend
omaclone_test_cfg secrets.backend locked
rm -f "$NAS_BACKUP_STATE_DIR"/last-result*.json
set +e
omaclone_cli clone --cron >/tmp/omaclone-cron-out.$$ 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "locked --cron should exit 0, got $rc: $(cat /tmp/omaclone-cron-out.$$)"
[[ "$(omaclone_last_result status)" == skip ]] || fail "locked: expected skip, got $(omaclone_last_result status)"
[[ "$(omaclone_last_result reason)" == password ]] || fail "locked: expected reason=password, got $(omaclone_last_result reason)"

# 4. missing disk UUID (removable, not connected)
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg transport.backend disk
omaclone_test_cfg transport.uuid "DEAD-BEEF-NOT-A-DISK"
omaclone_test_cfg transport.mountpoint ""
omaclone_test_cfg restic.repo "/mnt/nowhere/omaclone/repo"
omaclone_test_cfg locations.loc.backend disk
omaclone_test_cfg locations.loc.uuid "DEAD-BEEF-NOT-A-DISK"
omaclone_test_cfg locations.loc.repo "/mnt/nowhere/omaclone/repo"
omaclone_test_cfg locations.loc.schedule on
rm -f "$NAS_BACKUP_STATE_DIR"/last-result*.json
set +e
omaclone_cli clone --cron >/tmp/omaclone-cron-out.$$ 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "missing disk should exit 0, got $rc: $(cat /tmp/omaclone-cron-out.$$)"
[[ "$(omaclone_last_result status)" == skip ]] || fail "disk: expected skip, got $(omaclone_last_result status)"
printf '%s\n' "$(omaclone_last_result message)" | grep -qi "not connected" \
  || fail "disk: expected not connected, got $(omaclone_last_result message)"

# 5. transport not ready / not mounted
omaclone_test_cfg transport.backend not-ready
omaclone_test_cfg transport.uuid ""
omaclone_test_cfg restic.repo "$repo"
omaclone_test_cfg locations.loc.backend not-ready
omaclone_test_cfg locations.loc.uuid ""
omaclone_test_cfg locations.loc.repo "$repo"
omaclone_test_cfg locations.loc.schedule on
rm -f "$NAS_BACKUP_STATE_DIR"/last-result*.json
set +e
omaclone_cli clone --cron >/tmp/omaclone-cron-out.$$ 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "not-ready should exit 0, got $rc: $(cat /tmp/omaclone-cron-out.$$)"
[[ "$(omaclone_last_result status)" == skip ]] || fail "not-ready: expected skip, got $(omaclone_last_result status)"
printf '%s\n' "$(omaclone_last_result message)" | grep -qi "not mounted" \
  || fail "not-ready: expected not mounted, got $(omaclone_last_result message)"

# 6. S3 without keys is a password skip, not a green "not mounted"
omaclone_test_cfg transport.backend s3
omaclone_test_cfg restic.repo "s3:https://example.invalid/bucket/omaclone"
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg locations.loc.backend s3
omaclone_test_cfg locations.loc.repo "s3:https://example.invalid/bucket/omaclone"
omaclone_test_cfg locations.loc.uuid ""
omaclone_test_cfg locations.loc.schedule on
rm -f "$NAS_BACKUP_STATE_DIR"/last-result*.json
set +e
omaclone_cli clone --cron >/tmp/omaclone-cron-out.$$ 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "s3 --cron should exit 0, got $rc: $(cat /tmp/omaclone-cron-out.$$)"
[[ "$(omaclone_last_result status)" == skip ]] || fail "s3: expected skip, got $(omaclone_last_result status)"
[[ "$(omaclone_last_result reason)" == password ]] || fail "s3: expected reason=password, got $(omaclone_last_result reason)"
printf '%s\n' "$(omaclone_last_result message)" | grep -qi "s3" \
  || fail "s3: message should mention S3, got $(omaclone_last_result message)"
sev=$(omaclone_cli status --json | jq -r '.severity')
[[ "$sev" == warning ]] || fail "s3 skip must not look healthy, severity=$sev"

# 7. pre-restic failure is fail-closed (non-zero), not a silent restic run
omaclone_install_user_backend transport pre-fail "$ROOT/tests/backends/transport/pre-fail"
omaclone_test_cfg transport.backend pre-fail
omaclone_test_cfg restic.repo "$repo"
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg locations.loc.backend pre-fail
omaclone_test_cfg locations.loc.repo "$repo"
omaclone_test_cfg locations.loc.schedule on
rm -f "$NAS_BACKUP_STATE_DIR"/last-result*.json
set +e
omaclone_cli clone --cron >/tmp/omaclone-cron-out.$$ 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "pre-restic fail should be non-zero: $(cat /tmp/omaclone-cron-out.$$)"
printf '%s\n' "$(cat /tmp/omaclone-cron-out.$$)" | grep -qi "pre-restic\|prepare restic" \
  || fail "pre-restic fail should mention prepare/pre-restic: $(cat /tmp/omaclone-cron-out.$$)"

rm -f /tmp/omaclone-cron-out.$$
echo OK
