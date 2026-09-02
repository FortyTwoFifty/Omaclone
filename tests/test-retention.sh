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
unset NAS_BACKUP_LIB_LOADED

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/locations.sh"

OMACLONE_SKIP_SYSTEMD=1

[[ "$(retention_preset)" == standard ]] || fail "default preset: $(retention_preset)"
[[ "$(retention_label)" == *"6 months"* ]] || fail "default label: $(retention_label)"
[[ "$(retention_label last-5)" == "Last 5 clones" ]] || fail "last-5 label"
[[ "$(retention_label week)" == "Last 7 days" ]] || fail "week label"
[[ "$(retention_label month)" == "Last 30 days" ]] || fail "month label"

args=$(retention_forget_args last-5 | tr '\n' ' ')
[[ "$args" == *"--keep-last 5"* ]] || fail "last-5 args: $args"
args=$(retention_forget_args month | tr '\n' ' ')
[[ "$args" == *"--keep-daily 30"* ]] || fail "month args: $args"

config_set retention.preset week
[[ "$(retention_preset)" == week ]] || fail "set preset"
[[ "$(retention_label)" == "Last 7 days" ]] || fail "set label"

write_repo_stats 12 20761058562 11153451475
read -r c s p < <(read_repo_stats)
[[ "$c" == 12 ]] || fail "count $c"
[[ "$s" == 20761058562 ]] || fail "restore size $s"
[[ "$p" == 11153451475 ]] || fail "packed size $p"
human=$(human_bytes 21026877221)
[[ "$human" == "19.583 GiB" ]] || fail "human $human (want 19.583 GiB)"
human_m=$(human_bytes 123456789)
[[ "$human_m" == *"MiB" ]] || fail "human MiB $human_m"

config_set locations.ids "nas,usb"
config_set locations.active nas
write_repo_stats 3 0 0 "nas"
config_set locations.active usb
write_repo_stats 1 0 0 "usb"
[[ -f "$NAS_BACKUP_STATE_DIR/repo-stats-nas.json" ]] || fail "(b) missing nas stats file"
[[ -f "$NAS_BACKUP_STATE_DIR/repo-stats-usb.json" ]] || fail "(b) missing usb stats file"
read -r c _ < <(read_repo_stats)
[[ "$c" == 1 ]] || fail "(b-1) usb cache read: $c (want 1, not 3)"
config_set locations.active nas
read -r c _ < <(read_repo_stats)
[[ "$c" == 3 ]] || fail "(b-2) nas cache read after usb write: $c (want 3)"
config_set locations.active usb
read -r c _ < <(read_repo_stats)
[[ "$c" == 1 ]] || fail "(b-3) usb cache still 1 after nas reread: $c"

config_set locations.ids ""
config_set locations.active ""
write_repo_stats 5 0 0
read -r c _ < <(read_repo_stats)
[[ "$c" == 5 ]] || fail "(b-4) legacy global read: $c (want 5)"

got=$(map_restic_repo_onto_mount /mnt/external-Omaclone/omaclone/repo /mnt/external-Omaclone "/run/media/user/USB Drive")
[[ "$got" == "/run/media/user/USB Drive/omaclone/repo" ]] || fail "map onto live mount: $got"
got=$(map_restic_repo_onto_mount /other/repo /mnt/external-Omaclone "/run/media/user/USB Drive")
[[ "$got" == "/run/media/user/USB Drive/omaclone/repo" ]] || fail "map default kit: $got"

local_repo_dir="$NAS_BACKUP_USER_CONFIG_DIR/fake-repo"
mkdir -p "$local_repo_dir/snapshots"
touch "$local_repo_dir/snapshots/aaaaaaaa"
config_set restic.repo "$local_repo_dir"
lc=$(local_snapshot_count) || fail "(c) local_snapshot_count failed"
[[ "$lc" == 1 ]] || fail "(c) snapshot count: $lc (want 1)"

touch "$local_repo_dir/snapshots/bbbbbbbb"
touch "$local_repo_dir/snapshots/cccccccc"
lc=$(local_snapshot_count) || fail "(c2) local_snapshot_count failed"
[[ "$lc" == 3 ]] || fail "(c2) snapshot count: $lc (want 3)"

touch "$local_repo_dir/snapshots/.hidden"
lc=$(local_snapshot_count) || fail "(c3) local_snapshot_count failed"
[[ "$lc" == 3 ]] || fail "(c3) dotfile excluded: $lc (want 3)"

mkdir -p "$local_repo_dir/snapshots/subdir"
lc=$(local_snapshot_count) || fail "(c4) local_snapshot_count failed"
[[ "$lc" == 3 ]] || fail "(c4) subdir excluded: $lc (want 3)"

config_set restic.repo "s3:bucket/path"
if local_snapshot_count; then
  fail "(d) s3 repo should not return success"
fi

[[ "$(clone_count_label 0)" == "0 clones" ]] || fail "clone_count_label 0"
[[ "$(clone_count_label 1)" == "1 clone" ]] || fail "clone_count_label 1"
[[ "$(clone_count_label 7)" == "7 clones" ]] || fail "clone_count_label 7"

config_set restic.repo "$local_repo_dir"
config_set locations.ids local
config_set locations.active local
rm -f "$NAS_BACKUP_STATE_DIR"/repo-stats*.json
n=$(record_clone_count local) || fail "(e) record_clone_count failed"
[[ "$n" == 3 ]] || fail "(e) record_clone_count: $n (want 3)"
[[ -f "$NAS_BACKUP_STATE_DIR/repo-stats-local.json" ]] || fail "(e) missing per-location stats"
got=$(jq -r '.snapshotCount' "$NAS_BACKUP_STATE_DIR/repo-stats-local.json")
[[ "$got" == 3 ]] || fail "(e) cached snapshotCount: $got"

rm -f "$NAS_BACKUP_STATE_DIR"/repo-stats*.json
n=$(refresh_clone_count_on_connect local) || fail "(e2) refresh on connect failed"
[[ "$n" == 3 ]] || fail "(e2) refresh on connect: $n (want 3)"
got=$(jq -r '.snapshotCount' "$NAS_BACKUP_STATE_DIR/repo-stats-local.json")
[[ "$got" == 3 ]] || fail "(e2) cached after connect: $got"

# Setup of a new location must not overwrite another location's cache.
write_repo_stats 9 0 0 other
rm -f "$NAS_BACKUP_STATE_DIR/repo-stats.json"
n=$(record_clone_count "") || fail "(f) record with empty loc id failed"
[[ "$n" == 3 ]] || fail "(f) global record: $n (want 3)"
[[ -f "$NAS_BACKUP_STATE_DIR/repo-stats.json" ]] || fail "(f) missing global stats"
got=$(jq -r '.snapshotCount' "$NAS_BACKUP_STATE_DIR/repo-stats-other.json")
[[ "$got" == 9 ]] || fail "(f) must not clobber other location cache: $got"
got=$(jq -r '.locationId' "$NAS_BACKUP_STATE_DIR/repo-stats.json")
[[ "$got" == "" ]] || fail "(f) global locationId should be empty, got $got"

if grep -qi password "$NAS_BACKUP_CONFIG"; then
  fail "password leaked into config"
fi

echo "OK"
