#!/usr/bin/env bash
# Opt-in live NFS round-trip on a mounted Omaclone NAS share.
# Skips unless OMACLONE_NAS_LIVE=1. Never touches the production restic repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

if [[ "${OMACLONE_NAS_LIVE:-}" != 1 ]]; then
  echo "SKIP tests/test-nas-live.sh (set OMACLONE_NAS_LIVE=1 to run)"
  exit 0
fi

need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
need restic
need jq
need python3
need gum

NAS_MP="${OMACLONE_NAS_MOUNT:-/mnt/Omaclone-NAS}"
NAS_URI="${OMACLONE_NAS_URI:-10.10.0.10:/mnt/plumbus/Omaclone}"

findmnt -n "$NAS_MP" >/dev/null 2>&1 || fail "NAS mountpoint is not mounted: $NAS_MP"
src=$(findmnt -n -t nfs,nfs4 -o SOURCE --target "$NAS_MP" 2>/dev/null | awk 'NR==1 { print; exit }')
[[ -n "$src" ]] || fail "$NAS_MP is mounted but not nfs/nfs4"
echo "live nfs: $src -> $NAS_MP"

probe="$NAS_MP/.omaclone-live-write-test.$$"
if ! ( umask 077; : >"$probe" ) 2>/dev/null; then
  fail "NAS share is not writable as uid $(id -u) at $NAS_MP"
fi
rm -f "$probe"

export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env
omaclone_install_dummy_secrets

runid="omaclone-test-$$"
test_root="$NAS_MP/$runid"
repo="$test_root/repo"
mkdir -p "$test_root"
omaclone_test_cleanup() {
  rm -rf "$OMACLONE_TEST_HOME" || true
  if [[ -n "${test_root:-}" && -d "$test_root" ]]; then
    chmod -R u+w "$test_root" 2>/dev/null || true
    rm -rf "$test_root" || true
  fi
}
trap 'omaclone_test_cleanup' EXIT

source "$ROOT/scripts/nfs-lib.sh"

nfs_already_mounted "$NAS_URI" "$NAS_MP" \
  || fail "nfs_already_mounted should succeed for the live share"
if nfs_mountpoint_busy "$NAS_URI" "$NAS_MP"; then
  fail "live share should not be busy for its own URI"
fi
nfs_mountpoint_busy "10.10.0.10:/mnt/other-not-this-export" "$NAS_MP" \
  || fail "a different NFS URI on the live mountpoint must be busy"

# Same mountpoint (so nfs ready/findmnt works), isolated repo next to production kit.
omaclone_test_cfg transport.backend nfs
omaclone_test_cfg transport.uri "$NAS_URI"
omaclone_test_cfg transport.mountpoint "$NAS_MP"
omaclone_test_cfg restic.repo "$repo"
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg secrets.keyring_offer declined
omaclone_test_cfg destination.profile nas
omaclone_test_cfg destination.vendor truenas
omaclone_test_cfg retention.preset last-5
omaclone_test_cfg locations.ids nas-test
omaclone_test_cfg locations.active nas-test
omaclone_test_cfg locations.nas-test.backend nfs
omaclone_test_cfg locations.nas-test.uri "$NAS_URI"
omaclone_test_cfg locations.nas-test.mountpoint "$NAS_MP"
omaclone_test_cfg locations.nas-test.repo "$repo"
omaclone_test_cfg locations.nas-test.label "NAS test"
omaclone_test_cfg locations.nas-test.profile nas
omaclone_test_cfg locations.nas-test.schedule on

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/backend.sh"
nas_backup_backend_run transport nfs ready \
  || fail "nfs ready should succeed on the live automount"

mkdir -p "$HOME/identity" "$HOME/.config/omaclone-app"
printf 'hello-from-nas-live\n' >"$HOME/identity/marker.txt"
printf 'dotfile\n' >"$HOME/.config/omaclone-app/settings"

# Must skip bootstrap-install: it copies to $mountpoint/omaclone (production kit).
export OMACLONE_SKIP_BOOTSTRAP=1
omaclone_cli init
[[ -f "$repo/config" ]] || fail "restic init did not create $repo/config"
prod_repo="$NAS_MP/omaclone/repo/config"
[[ -f "$prod_repo" ]] || fail "sanity: production repo config missing (refusing to continue)"
[[ "$(readlink -f "$repo/config")" != "$(readlink -f "$prod_repo")" ]] \
  || fail "test repo resolved to the production repo"

omaclone_cli clone --cron >/tmp/omaclone-nas-live-clone.$$ 2>&1 \
  || { cat /tmp/omaclone-nas-live-clone.$$; fail "clone --cron failed"; }
rm -f /tmp/omaclone-nas-live-clone.$$
[[ "$(omaclone_last_result status)" == ok ]] \
  || fail "clone did not write last-result ok: $(omaclone_last_result status) $(omaclone_last_result message)"

st=$(omaclone_cli status --json)
echo "$st" | jq -e '.connected == true' >/dev/null || fail "status connected: $st"
echo "$st" | jq -e '.transportReady == true' >/dev/null || fail "status transportReady: $st"
echo "$st" | jq -e '.locationId == "nas-test"' >/dev/null || fail "status locationId: $st"
echo "$st" | jq -e '.snapshotCount >= 1' >/dev/null || fail "status snapshotCount: $st"
echo "$st" | jq -e --arg mp "$NAS_MP" '.watchPath == $mp' >/dev/null \
  || fail "status watchPath should be mountpoint: $st"

omaclone_cli check
omaclone_cli verify

pwfile=$(mktemp)
printf '%s' "dummy-password-not-for-real-repos" >"$pwfile"
sid=$(restic --password-file "$pwfile" --repo "$repo" snapshots --json | jq -r '.[0].short_id')
[[ -n "$sid" && "$sid" != null ]] || fail "could not read snapshot id"

rm -f "$HOME/identity/marker.txt" "$HOME/.config/omaclone-app/settings"
omaclone_cli restore --snapshot "$sid" --blank-omarchy >/tmp/omaclone-nas-live-restore.$$ 2>&1 \
  || { cat /tmp/omaclone-nas-live-restore.$$; fail "restore --snapshot failed"; }
rm -f /tmp/omaclone-nas-live-restore.$$
got=$(cat "$HOME/identity/marker.txt")
[[ "$got" == "hello-from-nas-live" ]] || fail "restored marker mismatch: $got"
[[ -f "$HOME/.config/omaclone-app/settings" ]] || fail "restore did not write dotfile"
[[ ! -e "$HOME/etc/fstab" ]] || fail "restore wrote etc/fstab into the target home"

doc=$(omaclone_cli doctor)
printf '%s\n' "$doc" | grep -q "writable: yes" || fail "doctor should report writable: $doc"
printf '%s\n' "$doc" | grep -q "restic config: present" || fail "doctor should see restic config: $doc"
printf '%s\n' "$doc" | grep -qi "cannot write" && fail "doctor printed uid mismatch despite writable share"

# Bootstrap into the *test* dir, not the production kit.
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$test_root" "$NAS_BACKUP_CONFIG"
[[ -x "$test_root/restore" ]] || fail "live kit restore missing"
python3 "$ROOT/scripts/bootstrap_copy.py" --verify "$test_root/SHA256SUMS" "$test_root/omaclone" \
  || fail "live kit SHA256SUMS did not verify"
if grep -qiE 'password\s*=' "$test_root/config.toml"; then
  fail "live kit config.toml leaked a password key"
fi
# Kit launcher should prefer a git plugin if present, else the copied tree.
"$test_root/restore" -h >/tmp/omaclone-nas-live-kit-help.$$ 2>&1 \
  || true
if grep -qi "UNTRUSTED" /tmp/omaclone-nas-live-kit-help.$$; then
  fail "trusted kit restore demanded UNTRUSTED: $(cat /tmp/omaclone-nas-live-kit-help.$$)"
fi
rm -f /tmp/omaclone-nas-live-kit-help.$$

omaclone_cli forget --yes "$sid"
left=$(restic --password-file "$pwfile" --repo "$repo" snapshots --json | jq 'length')
rm -f "$pwfile"
[[ "$left" == 0 ]] || fail "forget left $left snapshot(s) in the test repo"
[[ -f "$prod_repo" ]] || fail "forget/cleanup touched the production repo"

echo OK
