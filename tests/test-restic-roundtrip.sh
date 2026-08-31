#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env

need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
need restic
need jq
need rsync
need python3
need gum

omaclone_install_dummy_secrets

# Repo lives outside $HOME so clone does not try to snapshot itself.
repo_parent=$(mktemp -d)
repo="$repo_parent/omaclone/repo"
mkdir -p "$(dirname "$repo")" "$HOME/identity"
trap 'rm -rf "$OMACLONE_TEST_HOME" "$repo_parent"' EXIT
printf 'hello-from-%s\n' "omaclone-roundtrip" >"$HOME/identity/marker.txt"
mkdir -p "$HOME/.config/omaclone-app"
printf 'dotfile\n' >"$HOME/.config/omaclone-app/settings"

omaclone_test_cfg transport.backend local
omaclone_test_cfg transport.mountpoint "$repo_parent"
omaclone_test_cfg restic.repo "$repo"
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg secrets.keyring_offer declined
omaclone_test_cfg destination.profile local
omaclone_test_cfg retention.preset last-5
omaclone_test_cfg locations.ids local
omaclone_test_cfg locations.active local
omaclone_test_cfg locations.local.backend local
omaclone_test_cfg locations.local.repo "$repo"
omaclone_test_cfg locations.local.mountpoint "$repo_parent"
omaclone_test_cfg locations.local.schedule on
omaclone_test_cfg locations.local.label Local
omaclone_test_cfg locations.local.profile local

omaclone_cli init
[[ -f "$repo/config" ]] || fail "restic init did not create $repo/config"

omaclone_cli clone --cron >/tmp/omaclone-roundtrip-clone.$$ 2>&1 \
  || { cat /tmp/omaclone-roundtrip-clone.$$; fail "clone --cron failed"; }
rm -f /tmp/omaclone-roundtrip-clone.$$
[[ "$(omaclone_last_result status)" == ok ]] || fail "clone did not write last-result ok: $(omaclone_last_result status) $(omaclone_last_result message)"

pwfile=$(mktemp)
printf '%s' "dummy-password-not-for-real-repos" >"$pwfile"
n=$(restic --password-file "$pwfile" --repo "$repo" snapshots --json | jq 'length')
[[ "$n" -ge 1 ]] || fail "expected at least 1 restic snapshot, got $n"
sid=$(restic --password-file "$pwfile" --repo "$repo" snapshots --json | jq -r '.[0].short_id')
[[ -n "$sid" && "$sid" != null ]] || fail "could not read snapshot id"

omaclone_cli check

rm -f "$HOME/identity/marker.txt" "$HOME/.config/omaclone-app/settings"
rmdir "$HOME/.config/omaclone-app" 2>/dev/null || true
[[ ! -e "$HOME/identity/marker.txt" ]] || fail "pre-restore cleanup left marker.txt"

# Same HOME as clone: restic stores absolute paths, and restore remaps $staging$HOME.
# A small temp home is "fresh" so the TUI will not demand typing RESTORE.
omaclone_cli restore --snapshot "$sid" >/tmp/omaclone-roundtrip-restore.$$ 2>&1 \
  || { cat /tmp/omaclone-roundtrip-restore.$$; fail "restore --snapshot failed"; }
rm -f /tmp/omaclone-roundtrip-restore.$$

[[ -f "$HOME/identity/marker.txt" ]] || fail "restore did not write identity/marker.txt"
got=$(cat "$HOME/identity/marker.txt")
[[ "$got" == "hello-from-omaclone-roundtrip" ]] || fail "restored marker mismatch: $got"
[[ -f "$HOME/.config/omaclone-app/settings" ]] || fail "restore did not write dotfile"

[[ ! -e "$HOME/etc/fstab" ]] || fail "restore wrote etc/fstab into the target home"
if [[ -f "$NAS_BACKUP_STATE_DIR/staging/etc.tar" ]]; then
  tar -tf "$NAS_BACKUP_STATE_DIR/staging/etc.tar" | grep -q 'etc/fstab' \
    && fail "etc.tar contains fstab"
fi

restic --password-file "$pwfile" --repo "$repo" unlock >/dev/null 2>&1 || true
omaclone_cli forget --yes "$sid"
left=$(restic --password-file "$pwfile" --repo "$repo" snapshots --json | jq 'length')
rm -f "$pwfile"
[[ "$left" == 0 ]] || fail "forget left $left snapshot(s)"

echo OK
