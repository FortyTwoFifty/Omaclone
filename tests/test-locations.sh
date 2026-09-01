#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

export NAS_BACKUP_ROOT="$ROOT"
NAS_BACKUP_USER_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR"' EXIT
export NAS_BACKUP_USER_CONFIG_DIR
export NAS_BACKUP_STATE_DIR="$NAS_BACKUP_USER_CONFIG_DIR/state"
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"
export OMACLONE_SKIP_SYSTEMD=1
export OMACLONE_SKIP_DISCOVER=1
unset NAS_BACKUP_LIB_LOADED OMACLONE_LOCATIONS_LOADED

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/locations.sh"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.mode cold
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.uuid "AAAA-1111"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.mountpoint "/mnt/omaclone2"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set restic.repo "/mnt/omaclone2/omaclone/repo"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.uri "10.10.0.10:/mnt/pool/backups"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set destination.profile disk

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.label "USB stick"
got=$(python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get locations.usb.label)
[[ "$got" == "USB stick" ]] || fail "rsplit get: $got"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids ""
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active ""

migrate_locations
[[ "$(config_get locations.active)" == usb ]] || fail "active after migrate: $(config_get locations.active)"
ids=$(config_get locations.ids)
printf '%s\n' "$ids" | grep -q usb || fail "ids missing usb: $ids"
printf '%s\n' "$ids" | grep -q nas || fail "ids missing nas from leftover NFS uri: $ids"
[[ "$(location_get usb schedule)" == off ]] || fail "usb should be manual: $(location_get usb schedule)"
[[ "$(location_get nas schedule)" == on ]] || fail "nas should be daily: $(location_get nas schedule)"
[[ "$(location_get nas backend)" == nfs ]] || fail "nas backend"
[[ "$(location_get nas uri)" == "10.10.0.10:/mnt/pool/backups" ]] || fail "nas uri"

location_activate nas
[[ "$(config_get transport.backend)" == nfs ]] || fail "switch did not apply nfs"
[[ "$(config_get restic.repo)" == "/mnt/omaclone/omaclone/repo" ]] || fail "nas repo: $(config_get restic.repo)"
[[ "$(location_active_id)" == nas ]] || fail "active after switch"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set restic.repo "/mnt/external-Omaclone/repo"
location_sync_active
[[ "$(config_get transport.backend)" == nfs ]] || fail "sync did not restore nfs: $(config_get transport.backend)"
[[ "$(config_get restic.repo)" == "/mnt/omaclone/omaclone/repo" ]] || fail "sync did not restore repo: $(config_get restic.repo)"

location_activate usb
[[ "$(config_get transport.backend)" == disk ]] || fail "switch back to disk"
[[ "$(config_get transport.mode)" == cold ]] || fail "usb mode should stay cold, got $(config_get transport.mode)"

json=$(location_list_json)
echo "$json" | jq -e '.[] | select(.id=="usb")' >/dev/null || fail "list json usb"
echo "$json" | jq -e '.[] | select(.id=="nas")' >/dev/null || fail "list json nas"

location_ids_add nas
location_ids_add nas
ids=$(config_get locations.ids)
[[ "$ids" == *nas* ]] || fail "nas missing after re-add"
case ",$ids," in
  *,nas,nas,*) fail "duplicate nas in ids: $ids" ;;
esac
count=$(location_ids | grep -cx nas || true)
[[ "$count" == 1 ]] || fail "location_ids printed $count nas rows"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "nas,nas,ghost"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ghost.label "Ghost"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ghost.mountpoint "/mnt/nowhere"
json=$(location_list_json)
n_nas=$(echo "$json" | jq '[.[] | select(.id=="nas")] | length')
n_ghost=$(echo "$json" | jq '[.[] | select(.id=="ghost")] | length')
[[ "$n_nas" == 1 ]] || fail "list json should dedupe nas, got $n_nas"
[[ "$n_ghost" == 0 ]] || fail "list json should hide locations with no backend"

location_ids_compact
ids=$(config_get locations.ids)
case ",$ids," in
  *,nas,nas,*) fail "compact left duplicate nas: $ids" ;;
  *,ghost,*) fail "compact left stub ghost: $ids" ;;
esac
printf '%s\n' "$ids" | grep -q nas || fail "compact dropped real nas"

incomplete=$(mktemp)
export NAS_BACKUP_CONFIG="$incomplete"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.backend nfs
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.uri "10.10.0.10:/export"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.mountpoint "/mnt/omaclone"
migrate_locations
[[ -z "$(config_get locations.ids)" ]] || fail "incomplete setup created locations: $(config_get locations.ids)"
rm -f "$incomplete"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "usb,nas"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active usb

mkdir -p "$NAS_BACKUP_STATE_DIR"
python3 -c '
import json, time, sys
data = {"status": "fail", "message": "usb clone failed", "unix": int(time.time()), "location": "usb"}
with open(sys.argv[1] + "/last-result.json", "w") as f: json.dump(data, f)
with open(sys.argv[1] + "/last-result-usb.json", "w") as f: json.dump(data, f)
' "$NAS_BACKUP_STATE_DIR"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active nas
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set restic.repo "/mnt/omaclone/omaclone/repo"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.backend nfs
got=$("$ROOT/scripts/omaclone" status --json | jq -r '.lastStatus')
[[ "$got" == "unknown" ]] || fail "per-location isolation: expected unknown for nas, got $got"

loc_field=$(jq -r '.location' "$NAS_BACKUP_STATE_DIR/last-result.json")
[[ "$loc_field" == "usb" ]] || fail "write_last_result should include location=usb in global file, got: $loc_field"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.backend nfs
json_skip=$(location_list_json)
echo "$json_skip" | jq -e '.[] | select(.source=="discovered")' >/dev/null 2>&1 && fail "SKIP_DISCOVER: discovered entries should not appear"

n_config=$(echo "$json_skip" | jq '[.[] | select(.source=="config")] | length')
[[ "$n_config" -ge 2 ]] || fail "SKIP_DISCOVER: expected >=2 config entries, got $n_config"

kit=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR" "$kit"' EXIT
mkdir -p "$kit/omaclone"
touch "$kit/omaclone/restore" "$kit/omaclone/config.toml"
unset OMACLONE_SKIP_DISCOVER
export OMACLONE_DISCOVER_TARGETS="$kit"
json_found=$(location_list_json)
n_disc=$(echo "$json_found" | jq --arg mp "$kit/omaclone" '[.[] | select(.source=="discovered" and .mountpoint==$mp)] | length')
[[ "$n_disc" == 1 ]] || fail "discover kit missing from location list: $json_found"
disc_backend=$(echo "$json_found" | jq -r --arg mp "$kit/omaclone" '.[] | select(.source=="discovered" and .mountpoint==$mp) | .backend')
[[ -n "$disc_backend" ]] || fail "discovered backend empty"
unset OMACLONE_DISCOVER_TARGETS
export OMACLONE_SKIP_DISCOVER=1

err=$(mktemp)
printf '%s\n' "Fatal: wrong password or no key found" >"$err"
got=$(restic_summarize_fail 1 "$err")
[[ "$got" == "Clone failed: restic password was rejected" ]] || fail "summarize password: $got"
printf '%s\n' "restic: Input/output error" >"$err"
got=$(restic_summarize_fail 1 "$err")
[[ "$got" == *"I/O error"* ]] || fail "summarize io: $got"
rm -f "$err"

repo_dir="$NAS_BACKUP_USER_CONFIG_DIR/fake-repo"
mkdir -p "$repo_dir"
touch "$repo_dir/config"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.backend local
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set restic.repo "$repo_dir"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set secrets.backend prompt
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active nas
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.backend local
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.repo "$repo_dir"
python3 -c '
import json, time, sys
data = {"status": "fail", "message": "Clone location is not readable (I/O error)", "unix": int(time.time()), "location": "nas"}
open(sys.argv[1] + "/last-result.json", "w").write(json.dumps(data))
open(sys.argv[1] + "/last-result-nas.json", "w").write(json.dumps(data))
' "$NAS_BACKUP_STATE_DIR"
sev=$("$ROOT/scripts/omaclone" status --json | jq -r '.severity')
[[ "$sev" == "error" ]] || fail "expected error severity, got $sev"
"$ROOT/scripts/omaclone" status --ack
sev=$("$ROOT/scripts/omaclone" status --json | jq -r '.severity')
acked=$("$ROOT/scripts/omaclone" status --json | jq -r '.issueAcked')
[[ "$acked" == "true" ]] || fail "expected issueAcked true, got $acked"
[[ "$sev" != "error" ]] || fail "acked fail should not stay error, got $sev"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set secrets.backend prompt
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active nas
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.backend local
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.repo "$repo_dir"

python3 -c '
import json, time, sys
data = {"status": "skip", "message": "Clone disk is not connected. Plug in the drive.", "unix": int(time.time()), "location": "nas"}
open(sys.argv[1] + "/last-result.json", "w").write(json.dumps(data))
open(sys.argv[1] + "/last-result-nas.json", "w").write(json.dumps(data))
' "$NAS_BACKUP_STATE_DIR"
got=$("$ROOT/scripts/omaclone" status --json)
sev=$(printf '%s' "$got" | jq -r '.severity')
title=$(printf '%s' "$got" | jq -r '.issueTitle')
conn=$(printf '%s' "$got" | jq -r '.connected')
[[ "$sev" == "ok" ]] || fail "disconnect recovery: expected ok, got $sev"
[[ "$title" == "" ]] || fail "disconnect recovery: expected empty issueTitle, got '$title'"
[[ "$conn" == "true" ]] || fail "disconnect recovery: expected connected true, got $conn"

python3 -c '
import json, time, sys
data = {"status": "skip", "message": "Automatic clones are off for this location.", "unix": int(time.time()), "location": "nas"}
open(sys.argv[1] + "/last-result.json", "w").write(json.dumps(data))
open(sys.argv[1] + "/last-result-nas.json", "w").write(json.dumps(data))
' "$NAS_BACKUP_STATE_DIR"
got=$("$ROOT/scripts/omaclone" status --json)
sev=$(printf '%s' "$got" | jq -r '.severity')
title=$(printf '%s' "$got" | jq -r '.issueTitle')
[[ "$sev" == "warning" ]] || fail "non-conn skip: expected warning, got $sev"
echo "$title" | grep -qi "skip" || fail "non-conn skip: issueTitle should mention skip, got '$title'"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.uuid "FAKE-UUID-NOT-REAL"
python3 -c '
import json, time, sys
data = {"status": "skip", "message": "Clone disk is not connected. Plug in the drive.", "unix": int(time.time()), "location": "nas"}
open(sys.argv[1] + "/last-result.json", "w").write(json.dumps(data))
open(sys.argv[1] + "/last-result-nas.json", "w").write(json.dumps(data))
' "$NAS_BACKUP_STATE_DIR"
got=$("$ROOT/scripts/omaclone" status --json)
sev=$(printf '%s' "$got" | jq -r '.severity')
conn=$(printf '%s' "$got" | jq -r '.connected')
title=$(printf '%s' "$got" | jq -r '.issueTitle')
[[ "$conn" == "false" ]] || fail "missing uuid: expected connected false, got $conn"
[[ "$sev" == "warning" ]] || fail "missing uuid: expected warning, got $sev"
echo "$title" | grep -qi "not connected" || fail "missing uuid: issueTitle should mention not connected, got '$title'"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.backend local
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.uuid ""
python3 -c '
import json, time, sys
data = {"status": "skip", "message": "Password is not available (unlock keyring or sign in)", "reason": "password", "unix": int(time.time()), "location": "nas"}
open(sys.argv[1] + "/last-result.json", "w").write(json.dumps(data))
open(sys.argv[1] + "/last-result-nas.json", "w").write(json.dumps(data))
' "$NAS_BACKUP_STATE_DIR"
got=$("$ROOT/scripts/omaclone" status --json)
sev=$(printf '%s' "$got" | jq -r '.severity')
kind=$(printf '%s' "$got" | jq -r '.issueKind')
title=$(printf '%s' "$got" | jq -r '.issueTitle')
err=$(printf '%s' "$got" | jq -r '.lastError')
[[ "$sev" == "warning" ]] || fail "password skip: expected warning, got $sev"
[[ "$kind" == "password_locked" ]] || fail "password skip: expected issueKind password_locked, got $kind"
echo "$title" | grep -qi "password manager" || fail "password skip: issueTitle should mention password manager, got '$title'"
echo "$err" | grep -qi "did not run" || fail "password skip: lastError should say the clone did not run, got '$err'"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "usb,nas"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active nas
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.backend nfs
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.uuid "AAAA-1111"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.label NAS
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.label "USB stick"
got=$("$ROOT/scripts/omaclone" status --json)
id=$(printf '%s' "$got" | jq -r '.locationId')
label=$(printf '%s' "$got" | jq -r '.locationLabel')
n_active=$(printf '%s' "$got" | jq '[.locations[] | select(.source=="config" and .active==true)] | length')
[[ "$id" == nas ]] || fail "plugin contract locationId: $id"
[[ "$label" == NAS ]] || fail "plugin contract locationLabel: $label"
[[ "$n_active" == 1 ]] || fail "plugin contract expected 1 active location, got $n_active"
echo "$got" | jq -e '.watchPaths | type == "array"' >/dev/null \
  || fail "plugin contract watchPaths should be an array: $got"
echo "$got" | jq -e '.watchPaths | index("/dev/disk/by-uuid/AAAA-1111")' >/dev/null \
  || fail "plugin contract watchPaths missing usb uuid: $got"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active ""
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids ""
got=$("$ROOT/scripts/omaclone" status --json) || fail "status --json exited $? with no locations"
printf '%s' "$got" | jq -e '.connected | type == "boolean"' >/dev/null \
  || fail "status --json connected should be boolean with no locations: $got"

kit=$(mktemp -d)
mkdir -p "$kit/omaclone"
touch "$kit/omaclone/restore" "$kit/omaclone/config.toml"

FAKE_FINDMNT_DIR=$(mktemp -d)
FAKE_FINDMNT="$FAKE_FINDMNT_DIR/findmnt"
cat >"$FAKE_FINDMNT" <<'WRAPPER'
#!/usr/bin/env bash
if [[ "$*" == *"-o"*"UUID"* ]]; then
  for arg in "$@"; do
    case "$arg" in
      /*)
        if [[ -d "$arg" ]] && echo "$arg" | grep -q "/tmp/"; then
          echo "DEDUP-UUID-MATCH"
          exit 0
        fi
        ;;
    esac
  done
fi
exec /usr/bin/findmnt "$@"
WRAPPER
chmod +x "$FAKE_FINDMNT"

unset OMACLONE_SKIP_DISCOVER
export OMACLONE_DISCOVER_TARGETS="$kit"
export PATH="$FAKE_FINDMNT_DIR:$PATH"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "usb,nas,dedup-disk"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.dedup-disk.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.dedup-disk.uuid "DEDUP-UUID-MATCH"
json=$(location_list_json)

n_dedup_disc=$(echo "$json" | jq '[.[] | select(.source=="discovered" and .uuid=="DEDUP-UUID-MATCH")] | length')
[[ "$n_dedup_disc" == 0 ]] || fail "dedup uuid: expected 0 discovered with matching uuid, got $n_dedup_disc"
kit_as_loc=$(echo "$json" | jq --arg mp "$kit" '[.[] | select(.mountpoint==$mp)] | length')
[[ "$kit_as_loc" == 0 ]] || fail "dedup uuid: kit should not be a second location, got $kit_as_loc"

unset OMACLONE_DISCOVER_TARGETS
export OMACLONE_SKIP_DISCOVER=1
export PATH="${PATH#"$FAKE_FINDMNT_DIR":}"
rm -rf "$FAKE_FINDMNT_DIR"

kit2=$(mktemp -d)
mkdir -p "$kit2/omaclone"
touch "$kit2/omaclone/restore" "$kit2/omaclone/config.toml"
ln -s "$kit2" "${kit2}-link"
unset OMACLONE_SKIP_DISCOVER
export OMACLONE_DISCOVER_TARGETS="$kit2
${kit2}-link"
json2=$(location_list_json)
n_kit_disc=$(echo "$json2" | jq '[.[] | select(.source=="discovered")] | length')
[[ "$n_kit_disc" == 1 ]] || fail "dedup kit+symlink: expected 1 discovered, got $n_kit_disc (json: $json2)"
unset OMACLONE_DISCOVER_TARGETS
export OMACLONE_SKIP_DISCOVER=1

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "nas,usb,usb-2"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active nas
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.backend nfs
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.uuid "CCCC-3333"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.label "Discovered USB Drive"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb-2.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb-2.uuid "CCCC-3333"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb-2.label "Discovered USB Drive"
json=$(location_list_json)
n_same=$(echo "$json" | jq '[.[] | select(.uuid=="CCCC-3333")] | length')
[[ "$n_same" == 1 ]] || fail "same-uuid config: expected 1 row, got $n_same ($json)"
n_nas=$(echo "$json" | jq '[.[] | select(.id=="nas")] | length')
[[ "$n_nas" == 1 ]] || fail "same-uuid config should still list nas"

found=$(location_find_id_by_uuid "CCCC-3333")
[[ "$found" == usb ]] || fail "find_id_by_uuid expected usb, got $found"

location_ids_compact
ids=$(config_get locations.ids)
echo ",$ids," | grep -q ',usb-2,' && fail "compact left usb-2 duplicate: $ids"
echo ",$ids," | grep -q ',usb,' || fail "compact dropped real usb: $ids"
echo ",$ids," | grep -q ',nas,' || fail "compact dropped nas: $ids"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "nas,usb,usb-2"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active usb-2
json=$(location_list_json)
kept=$(echo "$json" | jq -r '.[] | select(.uuid=="CCCC-3333") | .id')
[[ "$kept" == usb-2 ]] || fail "active duplicate should win, got $kept"
location_ids_compact
ids=$(config_get locations.ids)
echo ",$ids," | grep -q ',usb-2,' || fail "compact should keep active usb-2: $ids"
echo ",$ids," | grep -q ',usb,' && fail "compact kept both usb ids: $ids"
[[ "$(config_get locations.active)" == usb-2 ]] || fail "active should stay usb-2"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "usb,usb-2"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active usb
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb-2.uuid "BBBB-2222"
json=$(location_list_json)
n_disk=$(echo "$json" | jq '[.[] | select(.backend=="disk")] | length')
[[ "$n_disk" == 2 ]] || fail "distinct uuids should both list, got $n_disk"
location_ids_compact
ids=$(config_get locations.ids)
echo ",$ids," | grep -q ',usb,' || fail "distinct compact dropped usb: $ids"
echo ",$ids," | grep -q ',usb-2,' || fail "distinct compact dropped usb-2: $ids"
unset OMACLONE_SKIP_DISCOVER

kit_parent=$(mktemp -d)
mkdir -p "$kit_parent/omaclone"
touch "$kit_parent/omaclone/restore" "$kit_parent/omaclone/config.toml"
export OMACLONE_DISCOVER_TARGETS="$kit_parent"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "usb"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active usb
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.uuid ""
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.mountpoint "$kit_parent"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.label USB
json=$(location_list_json)
n_disc=$(echo "$json" | jq '[.[] | select(.source=="discovered")] | length')
[[ "$n_disc" == 0 ]] || fail "nested kit under config mount listed as discovered: $json"
n_usb=$(echo "$json" | jq '[.[] | select(.id=="usb")] | length')
[[ "$n_usb" == 1 ]] || fail "config usb missing after nested kit: $json"
unset OMACLONE_DISCOVER_TARGETS
export OMACLONE_SKIP_DISCOVER=1

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.uuid "NO-SUCH-UUID"
json=$(location_list_json)
got=$(echo "$json" | jq -r '.[] | select(.id=="usb") | .snapshotCount // "none"')
[[ "$got" == none ]] || fail "unplugged disk must not report a clone count: $json"

snap_repo=$(mktemp -d)
mkdir -p "$snap_repo/snapshots"
touch "$snap_repo/snapshots/one" "$snap_repo/snapshots/two"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.backend local
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.repo "$snap_repo"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.uuid ""
json=$(location_list_json)
got=$(echo "$json" | jq -r '.[] | select(.id=="usb") | .snapshotCount')
[[ "$got" == 2 ]] || fail "snapshotCount expected 2, got $got ($json)"

location_drop usb
ids=$(config_get locations.ids)
echo ",$ids," | grep -q ',usb,' && fail "drop left usb: $ids"
[[ "$(config_get locations.usb.backend)" == "" ]] || fail "drop left usb section"

empty_mp=$(mktemp -d)
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "ghost-disk"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active ghost-disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ghost-disk.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ghost-disk.uuid "GHOST-UUID"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ghost-disk.mountpoint "$empty_mp"
location_forget_absent_disks
echo ",$(config_get locations.ids)," | grep -q ',ghost-disk,' || fail "unplugged ghost should remain in config until remove"

rm -rf "$kit_parent" "$snap_repo" "$empty_mp"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "nas-only"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active nas-only
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas-only.backend nfs
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas-only.uri "10.10.0.5:/backup"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas-only.mountpoint "/mnt/omaclone"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set restic.repo "/mnt/omaclone/omaclone/repo"

location_drop nas-only
ids=$(config_get locations.ids)
[[ -z "$ids" ]] || fail "A: ids should be empty after dropping last, got '$ids'"
active=$(config_get locations.active)
[[ -z "$active" ]] || fail "A: active should be empty, got '$active'"
tb=$(config_get transport.backend)
[[ -z "$tb" ]] || fail "A: transport.backend should be empty, got '$tb'"
rr=$(config_get restic.repo)
[[ -z "$rr" ]] || fail "A: restic.repo should be empty, got '$rr'"

migrate_locations
ids2=$(config_get locations.ids)
[[ -z "$ids2" ]] || fail "A: migrate_locations recreated ids: $ids2"

got=$("$ROOT/scripts/omaclone" status --json)
echo "$got" | jq -e '.locations' >/dev/null || fail "A: status --json missing locations array"
n_nas=$(echo "$got" | jq '[.locations[] | select(.id=="nas-only")] | length')
[[ "$n_nas" == 0 ]] || fail "A: status --json should not recreate nas, got $n_nas entries"

kit=$(mktemp -d)
mkdir -p "$kit/omaclone"
touch "$kit/omaclone/restore" "$kit/omaclone/config.toml"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids "nas,usb"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active usb
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.backend nfs
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.mountpoint "$kit"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.nas.uri "10.10.0.5:/backup"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.backend disk
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.uuid "AAAA-1111"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.usb.repo "/mnt/omaclone2/omaclone/repo"

location_drop nas
unset OMACLONE_SKIP_DISCOVER
export OMACLONE_DISCOVER_TARGETS="$kit"
json=$(location_list_json)
n_nas_cfg=$(echo "$json" | jq '[.[] | select(.id=="nas")] | length')
[[ "$n_nas_cfg" == 0 ]] || fail "B: forgotten nas should not appear, got $n_nas_cfg"
n_disc_kit=$(echo "$json" | jq --arg mp "$kit/omaclone" '[.[] | select(.source=="discovered" and .mountpoint==$mp)] | length')
[[ "$n_disc_kit" == 0 ]] || fail "B: discovered kit should be hidden, got $n_disc_kit"
n_usb=$(echo "$json" | jq '[.[] | select(.id=="usb")] | length')
[[ "$n_usb" == 1 ]] || fail "B: usb should still appear, got $n_usb"
unset OMACLONE_DISCOVER_TARGETS
export OMACLONE_SKIP_DISCOVER=1

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.backend nfs
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.uri "10.10.0.5:/backup"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.mountpoint "$kit"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set restic.repo "$kit/omaclone/repo"
location_save_current nas

forgotten=$(config_get locations.forgotten)
case "|${forgotten}|" in
  *"|${kit}|"*|*"|${kit}/omaclone|"*) fail "C: forgotten should be cleared for re-saved nas, got '$forgotten'" ;;
esac
unset OMACLONE_SKIP_DISCOVER
export OMACLONE_DISCOVER_TARGETS="$kit"
json2=$(location_list_json)
n_nas_cfg2=$(echo "$json2" | jq '[.[] | select(.id=="nas" and .source=="config")] | length')
[[ "$n_nas_cfg2" == 1 ]] || fail "C: nas should appear source:config after re-save, got $n_nas_cfg2"
unset OMACLONE_DISCOVER_TARGETS
export OMACLONE_SKIP_DISCOVER=1

rm -rf "$kit_parent" "$snap_repo" "$empty_mp" "$kit"

[[ "$(location_default_label s3)" == "Cloud (S3)" ]] || fail "s3 default label: $(location_default_label s3)"
[[ "$(location_default_schedule s3)" == on ]] || fail "s3 default schedule should be on"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.ids ""
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.active ""
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set locations.migrated ""
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.backend s3
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set destination.profile cloud
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.endpoint "example.r2.cloudflarestorage.com"
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.bucket mybucket
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.prefix omaclone
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.region auto
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.tls 1
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set restic.repo "s3:https://example.r2.cloudflarestorage.com/mybucket/omaclone"
migrate_locations
[[ "$(config_get locations.active)" == cloud ]] || fail "s3 migrate active: $(config_get locations.active)"
ids=$(config_get locations.ids)
printf '%s\n' "$ids" | grep -q cloud || fail "s3 migrate ids missing cloud: $ids"
[[ "$(location_get cloud backend)" == s3 ]] || fail "s3 migrate backend"
[[ "$(location_get cloud endpoint)" == "example.r2.cloudflarestorage.com" ]] || fail "s3 migrate endpoint"
[[ "$(location_get cloud bucket)" == mybucket ]] || fail "s3 migrate bucket"
[[ "$(location_get cloud prefix)" == omaclone ]] || fail "s3 migrate prefix"
[[ "$(location_get cloud region)" == auto ]] || fail "s3 migrate region"
[[ "$(location_get cloud tls)" == 1 ]] || fail "s3 migrate tls"
[[ "$(location_get cloud schedule)" == on ]] || fail "s3 migrate schedule"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.backend local
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set restic.repo "$NAS_BACKUP_USER_CONFIG_DIR/local-repo"
mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/local-repo"
location_save_current local "Local" on
location_activate local
[[ "$(config_get transport.backend)" == local ]] || fail "switch to local"
location_activate cloud
[[ "$(config_get transport.backend)" == s3 ]] || fail "switch back to s3"
[[ "$(config_get transport.endpoint)" == "example.r2.cloudflarestorage.com" ]] || fail "apply endpoint"
[[ "$(config_get transport.bucket)" == mybucket ]] || fail "apply bucket"
[[ "$(config_get transport.prefix)" == omaclone ]] || fail "apply prefix"
[[ "$(config_get transport.region)" == auto ]] || fail "apply region"
[[ "$(config_get transport.tls)" == 1 ]] || fail "apply tls"
[[ "$(config_get restic.repo)" == "s3:https://example.r2.cloudflarestorage.com/mybucket/omaclone" ]] \
  || fail "apply repo: $(config_get restic.repo)"

json=$(location_list_json)
echo "$json" | jq -e '.[] | select(.id=="cloud" and .backend=="s3" and .connected==true)' >/dev/null \
  || fail "s3 location_list_json connected: $json"

echo "OK"
