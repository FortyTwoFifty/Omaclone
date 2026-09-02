#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

unit="$ROOT/systemd/omaclone.service"
timer="$ROOT/systemd/omaclone.timer"
prune="$ROOT/systemd/omaclone-prune.service"
prune_timer="$ROOT/systemd/omaclone-prune.timer"
retry="$ROOT/systemd/omaclone-keyring-retry.service"

for f in "$unit" "$timer" "$prune" "$prune_timer" "$retry"; do
  [[ -f "$f" ]] || fail "missing unit: $f"
done

grep -q 'ExecStart=.*omaclone clone --cron' "$unit" \
  || fail "omaclone.service must run clone --cron"
grep -q 'Type=oneshot' "$unit" || fail "omaclone.service should be oneshot"
grep -q 'TimeoutStartSec=6h' "$unit" \
  || fail "omaclone.service must set TimeoutStartSec=6h"
grep -q 'NoNewPrivileges=yes' "$unit" \
  || fail "omaclone.service must set NoNewPrivileges=yes"
grep -q 'PrivateTmp=yes' "$unit" \
  || fail "omaclone.service must set PrivateTmp=yes"

grep -q 'OnCalendar=' "$timer" || fail "omaclone.timer missing OnCalendar"
grep -q 'Persistent=true' "$timer" || fail "omaclone.timer should be Persistent"

grep -q 'ExecStart=.*omaclone prune --cron' "$prune" \
  || fail "omaclone-prune.service must run prune --cron"
grep -q 'TimeoutStartSec=2h' "$prune" \
  || fail "omaclone-prune.service must set TimeoutStartSec=2h"
grep -q 'NoNewPrivileges=yes' "$prune" \
  || fail "omaclone-prune.service must set NoNewPrivileges=yes"
grep -q 'PrivateTmp=yes' "$prune" \
  || fail "omaclone-prune.service must set PrivateTmp=yes"
grep -q 'OnCalendar=' "$prune_timer" || fail "omaclone-prune.timer missing OnCalendar"

grep -q 'ExecStart=.*omaclone wait-keyring' "$retry" \
  || fail "keyring-retry.service must run wait-keyring"
grep -q 'TimeoutStartSec=30min' "$retry" \
  || fail "keyring-retry.service must set TimeoutStartSec=30min"
grep -q 'NoNewPrivileges=yes' "$retry" \
  || fail "keyring-retry.service must set NoNewPrivileges=yes"
grep -q 'PrivateTmp=yes' "$retry" \
  || fail "keyring-retry.service must set PrivateTmp=yes"

echo OK
