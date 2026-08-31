set +o history 2>/dev/null || true
unset HISTFILE
set +x +v
set -euo pipefail

if [[ -n "${NAS_BACKUP_LIB_LOADED:-}" ]]; then
  return 0
fi
NAS_BACKUP_LIB_LOADED=1

APP_ID="omaclone"
APP_NAME="Omaclone"
PLUGIN_ID="omaclone.plugin"
PLUGIN_REPO_URL="https://github.com/FortyTwoFifty/Omaclone.git"

omaclone_plugin_dest() {
  printf '%s\n' "${OMACLONE_PLUGIN_DIR:-$HOME/.config/omarchy/plugins/$PLUGIN_ID}"
}

omaclone_link_cli() {
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$NAS_BACKUP_ROOT/scripts/omaclone" "$HOME/.local/bin/omaclone"
  ln -sfn "$HOME/.local/bin/omaclone" "$HOME/.local/bin/omarchy-backup"
  ln -sfn "$HOME/.local/bin/omaclone" "$HOME/.local/bin/nas-backup"
}

omaclone_unlink_if_points_at() {
  local link="$1" want="$2" target
  [[ -L "$link" ]] || return 0
  target=$(readlink -f "$link" 2>/dev/null || true)
  if [[ -n "$target" && -n "$want" && "$target" == "$want" ]]; then
    rm -f "$link"
  fi
}

omaclone_unlink_cli() {
  local cli
  cli=$(readlink -f "$NAS_BACKUP_ROOT/scripts/omaclone" 2>/dev/null || true)
  omaclone_unlink_if_points_at "$HOME/.local/bin/omarchy-backup" "$cli"
  omaclone_unlink_if_points_at "$HOME/.local/bin/nas-backup" "$cli"
  omaclone_unlink_if_points_at "$HOME/.local/bin/omaclone" "$cli"
}

omaclone_link_plugin() {
  local dest root_real dest_real=""
  dest=$(omaclone_plugin_dest)
  mkdir -p "$(dirname "$dest")"
  root_real=$(readlink -f "$NAS_BACKUP_ROOT")
  if [[ -e "$dest" || -L "$dest" ]]; then
    dest_real=$(readlink -f "$dest" 2>/dev/null || true)
  fi
  if [[ -n "$dest_real" && "$root_real" == "$dest_real" ]]; then
    return 0
  fi
  if [[ -d "$dest" && ! -L "$dest" ]]; then
    log "plugin already installed at $dest; not replacing with a symlink"
    return 0
  fi
  ln -sfn "$NAS_BACKUP_ROOT" "$dest"
}

omaclone_unlink_plugin() {
  local dest
  dest=$(omaclone_plugin_dest)
  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  fi
}

omaclone_install_menu() {
  local src dest
  src="$NAS_BACKUP_ROOT/omarchy-menu.jsonc"
  dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
  [[ -f "$src" ]] || return 0
  mkdir -p "$(dirname "$dest")"
  if python3 - "$src" "$dest" <<'PY'
import json
import pathlib
import re
import sys

src = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
dest_path = pathlib.Path(sys.argv[2])
dest_path.parent.mkdir(parents=True, exist_ok=True)
if not dest_path.exists() or dest_path.stat().st_size == 0:
    dest_path.write_text(json.dumps(src, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    sys.exit(0)

text = dest_path.read_text(encoding="utf-8")
try:
    dest = json.loads(text)
except json.JSONDecodeError:
    stripped = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    stripped = re.sub(r"(?m)//.*?$", "", stripped)
    stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
    try:
        dest = json.loads(stripped)
    except json.JSONDecodeError:
        sys.exit(2)

if not isinstance(dest, dict):
    sys.exit(2)
added = False
for key, value in src.items():
    if key not in dest:
        dest[key] = value
        added = True
if added:
    dest_path.write_text(json.dumps(dest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
  then
    return 0
  fi
  log "add Omaclone entries to $dest (see omarchy-menu.jsonc)"
}

_NAS_BACKUP_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT:-$(cd "$_NAS_BACKUP_LIB_DIR/.." && pwd)}"

_xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
_xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
_default_config_dir="$_xdg_config/omaclone"
_default_state_dir="$_xdg_data/omaclone"
_legacy_config_dirs=("$_xdg_config/omarchy-backup" "$_xdg_config/nas-backup")
_legacy_state_dirs=("$_xdg_data/omarchy-backup" "$_xdg_data/nas-backup")

omaclone_migrate_tree() {
  local old="$1" new="$2"
  [[ -d "$old" ]] || return 0
  if [[ -f "$new/config.toml" || -f "$new/last-result.json" ]]; then
    return 0
  fi
  mkdir -p "$new"
  cp -a "$old"/. "$new"/
}

if [[ -z "${NAS_BACKUP_USER_CONFIG_DIR:-}" ]]; then
  for _old in "${_legacy_config_dirs[@]}"; do
    omaclone_migrate_tree "$_old" "$_default_config_dir"
  done
  NAS_BACKUP_USER_CONFIG_DIR="$_default_config_dir"
fi
if [[ -z "${NAS_BACKUP_STATE_DIR:-}" ]]; then
  for _old in "${_legacy_state_dirs[@]}"; do
    omaclone_migrate_tree "$_old" "$_default_state_dir"
  done
  NAS_BACKUP_STATE_DIR="$_default_state_dir"
fi

NAS_BACKUP_CONFIG="${NAS_BACKUP_CONFIG:-$NAS_BACKUP_USER_CONFIG_DIR/config.toml}"
NAS_BACKUP_STAGING="$NAS_BACKUP_STATE_DIR/staging"
NAS_BACKUP_PWFILE=""
NAS_BACKUP_ENVFILE=""

OMACLONE_ROOT="$NAS_BACKUP_ROOT"
OMACLONE_USER_CONFIG_DIR="$NAS_BACKUP_USER_CONFIG_DIR"
OMACLONE_CONFIG="$NAS_BACKUP_CONFIG"
OMACLONE_STATE_DIR="$NAS_BACKUP_STATE_DIR"

mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR" "$NAS_BACKUP_STATE_DIR"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'omaclone: %s\n' "$*" >&2; exit 1; }

is_tty() { [[ -t 0 && -t 1 ]]; }

have() { command -v "$1" >/dev/null 2>&1; }

config_py() {
  python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$@"
}

config_get() {
  local key="$1"
  local default="${2:-}"
  config_py "$NAS_BACKUP_CONFIG" get "$key" "$default"
}

config_set() {
  config_py "$NAS_BACKUP_CONFIG" set "$1" "$2"
}

config_drop() {
  config_py "$NAS_BACKUP_CONFIG" drop "$1"
}

retention_preset() {
  config_get retention.preset standard
}

retention_label() {
  local preset="${1:-$(retention_preset)}"
  case "$preset" in
    last-5) printf '%s\n' "Last 5 clones" ;;
    week) printf '%s\n' "Last 7 days" ;;
    month) printf '%s\n' "Last 30 days" ;;
    quarter) printf '%s\n' "3 months" ;;
    year) printf '%s\n' "1 year" ;;
    standard) printf '%s\n' "7 days / 4 weeks / 6 months / 2 years" ;;
    *) printf '%s\n' "7 days / 4 weeks / 6 months / 2 years" ;;
  esac
}

retention_ids() {
  printf '%s\n' last-5 week month quarter year standard
}

retention_forget_args() {
  local preset="${1:-$(retention_preset)}"
  case "$preset" in
    last-5) printf '%s\n' --keep-last 5 ;;
    week) printf '%s\n' --keep-daily 7 ;;
    month) printf '%s\n' --keep-daily 30 ;;
    quarter) printf '%s\n' --keep-daily 7 --keep-weekly 4 --keep-monthly 3 ;;
    year) printf '%s\n' --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 1 ;;
    *) printf '%s\n' --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 2 ;;
  esac
}

write_repo_stats() {
  local count="${1:-0}" restore="${2:-0}" packed="${3:-0}" loc_id="${4:-}"
  if [[ -z "$loc_id" ]]; then
    loc_id=$(config_get locations.active 2>/dev/null || true)
  fi
  mkdir -p "$NAS_BACKUP_STATE_DIR"
  local global="$NAS_BACKUP_STATE_DIR/repo-stats.json"
  local per=""
  [[ -n "$loc_id" ]] && per="$NAS_BACKUP_STATE_DIR/repo-stats-${loc_id}.json"
  python3 - "$global" "$per" "$count" "$restore" "$packed" "$loc_id" <<'PY'
import json, sys, time
path, per_loc_path, count, restore, packed, loc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
def as_int(v):
    try:
        return int(v)
    except (ValueError, TypeError):
        return 0
data = {
    "snapshotCount": as_int(count),
    "restoreSizeBytes": as_int(restore),
    "repoSizeBytes": as_int(restore),
    "packedSizeBytes": as_int(packed),
    "locationId": loc if loc else "",
    "unix": int(time.time()),
}
import os, tempfile
from pathlib import Path

def atomic_write(dest, payload):
    dest = Path(dest)
    if not dest.name:
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(dest.parent), prefix=dest.name + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

atomic_write(path, data)
if per_loc_path:
    atomic_write(per_loc_path, data)
PY
}

read_repo_stats() {
  local path="$NAS_BACKUP_STATE_DIR/repo-stats.json"
  [[ -f "$path" ]] || { printf '%s\n' "0 0 0"; return 0; }

  if [[ -n "${OMACLONE_LOCATIONS_LOADED:-}" ]]; then
    local loc_id=""
    loc_id=$(location_active_id 2>/dev/null || true)
    if [[ -n "$loc_id" && -f "$NAS_BACKUP_STATE_DIR/repo-stats-${loc_id}.json" ]]; then
      path="$NAS_BACKUP_STATE_DIR/repo-stats-${loc_id}.json"
    else
      local _file_loc
      _file_loc=$(jq -r '.locationId // ""' "$path" 2>/dev/null || true)
      if [[ -z "$_file_loc" && -z "$loc_id" ]]; then
        :
      elif [[ "$_file_loc" == "$loc_id" ]]; then
        :
      else
        printf '%s\n' "0 0 0"
        return 0
      fi
    fi
  fi

  python3 - "$path" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    data = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    print("0 0 0")
    raise SystemExit(0)
restore = int(data.get("restoreSizeBytes") or data.get("repoSizeBytes") or 0)
packed = int(data.get("packedSizeBytes") or 0)
print(int(data.get("snapshotCount") or 0), restore, packed)
PY
}

human_bytes() {
  local n="${1:-0}"
  python3 - "$n" <<'PY'
import sys
n = int(sys.argv[1] or 0)
if n >= 1024 ** 4:
    print(f"{n / (1024 ** 4):.3f} TiB")
elif n >= 1024 ** 3:
    print(f"{n / (1024 ** 3):.3f} GiB")
elif n >= 1024 ** 2:
    print(f"{n / (1024 ** 2):.1f} MiB")
elif n >= 1024:
    print(f"{n / 1024:.1f} KiB")
else:
    print(f"{n} B")
PY
}

collect_repo_stats() {
  local table count restore packed
  table=$(restic_exec snapshots --json 2>/dev/null) || table="[]"
  count=$(printf '%s' "$table" | jq 'length' 2>/dev/null || echo 0)
  restore=$(printf '%s' "$table" | jq -r '[.[]] | max_by(.time) | .summary.total_bytes_processed // 0' 2>/dev/null || echo 0)
  if [[ -z "$restore" || "$restore" == 0 || "$restore" == null ]]; then
    restore=$(restic_exec stats --json 2>/dev/null | jq -r '.total_size // 0' 2>/dev/null || echo 0)
  fi
  packed=$(restic_exec stats --mode raw-data --json 2>/dev/null | jq -r '.total_size // 0' 2>/dev/null || echo 0)
  write_repo_stats "$count" "$restore" "$packed" "$(config_get locations.active 2>/dev/null || true)"
}

omaclone_kit_dir() {
  local mp="${1%/}"
  [[ -n "$mp" ]] || return 1
  printf '%s\n' "$mp/omaclone"
}

map_restic_repo_onto_mount() {
  local repo="${1:-}" configured="${2:-}" live="${3:-}" kit
  [[ -n "$repo" && -n "$live" ]] || return 1
  configured="${configured%/}"
  live="${live%/}"
  if [[ -n "$configured" && "$repo" == "$configured"/* ]]; then
    printf '%s\n' "$live/${repo#"$configured"/}"
    return 0
  fi
  kit=$(omaclone_kit_dir "$live")
  printf '%s\n' "$kit/repo"
}

restic_local_repo_path() {
  local repo live uuid mp
  repo=$(config_get restic.repo)
  [[ -n "$repo" ]] || return 1
  case "$repo" in
    /*) ;;
    *) return 1 ;;
  esac
  if [[ -d "$repo/snapshots" || -f "$repo/config" ]]; then
    printf '%s\n' "$repo"
    return 0
  fi
  uuid=$(config_get transport.uuid)
  [[ -n "$uuid" && -e "/dev/disk/by-uuid/$uuid" ]] || return 1
  live=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$uuid" 2>/dev/null | head -n 1)
  [[ -n "$live" ]] || return 1
  mp=$(config_get transport.mountpoint)
  repo=$(map_restic_repo_onto_mount "$repo" "$mp" "$live") || return 1
  [[ -d "$repo/snapshots" || -f "$repo/config" ]] || return 1
  printf '%s\n' "$repo"
}

local_snapshot_count() {
  local repo snap_dir count=0 f
  repo=$(restic_local_repo_path) || return 1
  snap_dir="$repo/snapshots"
  [[ -d "$snap_dir" ]] || return 1
  for f in "$snap_dir"/[!.]*; do
    [[ -f "$f" ]] && (( count++ )) || true
  done
  printf '%s\n' "$count"
  return 0
}

need_cmd() {
  local c
  for c in "$@"; do
    have "$c" || die "missing command: $c"
  done
}

dir_is_writable() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local probe="$dir/.omaclone-write-test.$$"
  if ( umask 077; : >"$probe" ) 2>/dev/null; then
    rm -f "$probe"
    return 0
  fi
  rm -f "$probe" 2>/dev/null || true
  return 1
}

explain_nfs_uid_mismatch() {
  local dir="${1:-/mnt/omaclone}"
  local owner
  owner=$(stat -c '%u:%g (%A)' "$dir" 2>/dev/null || echo unknown)
  cat >&2 <<EOF
omaclone: cannot write to $dir
  this machine: uid=$(id -u) gid=$(id -g) ($USER)
  NFS directory: $owner

NFS uses numeric UIDs. If the export is owned by a different uid than your
Linux user, writes fail even when the share is mounted.

  TrueNAS → Shares → Unix Shares (NFS) → this export → Advanced Options
    Mapall User  = the NAS account that owns the dataset
    Mapall Group = that account's group

  Synology → Control Panel → File Services → NFS → the export
    Map all users to admin, or set squash / anonuid to the folder owner.

Alternatively export the parent of the restic folder so bootstrap files can
sit next to the repo rather than inside it.

Then: touch $dir/.write-test  (should succeed) and re-run setup.
EOF
}

password_cleanup() {
  local f="${NAS_BACKUP_PWFILE:-}"
  NAS_BACKUP_PWFILE=""
  if [[ -n "$f" && -e "$f" ]]; then
    if have shred; then
      shred -u "$f" 2>/dev/null || rm -f "$f"
    else
      : >"$f"
      rm -f "$f"
    fi
  fi
  f="${NAS_BACKUP_ENVFILE:-}"
  NAS_BACKUP_ENVFILE=""
  if [[ -n "$f" && -e "$f" ]]; then
    if have shred; then
      shred -u "$f" 2>/dev/null || rm -f "$f"
    else
      : >"$f"
      rm -f "$f"
    fi
  fi
}

_nas_backup_on_exit() {
  password_cleanup
}

_nas_backup_on_signal() {
  local sig="${1:-INT}"
  password_cleanup
  trap - EXIT
  case "$sig" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
    *) exit 1 ;;
  esac
}

trap '_nas_backup_on_exit' EXIT
trap '_nas_backup_on_signal INT' INT
trap '_nas_backup_on_signal TERM' TERM
trap '_nas_backup_on_signal HUP' HUP

omaclone_acquire_lock() {
  local lock="$NAS_BACKUP_STATE_DIR/omaclone.lock"
  mkdir -p "$NAS_BACKUP_STATE_DIR"
  exec 9>"$lock"
  if ! flock -n 9; then
    die "another omaclone clone, prune, or forget is already running"
  fi
}

_password_tmpdir() {
  if [[ -d /dev/shm && -w /dev/shm ]]; then
    echo /dev/shm
  elif [[ -d /run/user/${UID:-$(id -u)} && -w /run/user/${UID:-$(id -u)} ]]; then
    echo "/run/user/${UID:-$(id -u)}"
  else
    die "no tmpfs directory available for a password file"
  fi
}

repo_initialized() {
  local repo
  repo=$(config_get restic.repo)
  [[ -n "$repo" ]] || return 1
  case "$repo" in
    s3:*|sftp:*)
      [[ "$(config_get restic.initialized)" == 1 ]] && return 0
      if [[ -f "$NAS_BACKUP_STATE_DIR/last-result.json" ]]; then
        local status
        status=$(jq -r '.status' "$NAS_BACKUP_STATE_DIR/last-result.json" 2>/dev/null || true)
        [[ "$status" == "ok" ]] && return 0
      fi
      return 1
      ;;
    *)
      [[ -f "$repo/config" ]]
      ;;
  esac
}

mark_repo_initialized() {
  config_set restic.initialized 1
}

setup_is_unfinished() {
  local transport secrets
  transport=$(config_get transport.backend)
  [[ -n "$transport" ]] || return 1
  secrets=$(config_get secrets.backend)
  [[ -n "$secrets" ]] || return 0
  repo_initialized || return 0
  [[ -z "$(config_get locations.ids)" ]] && return 0
  return 1
}

setup_is_configured() {
  [[ -n "$(config_get transport.backend)" ]]
}

password_chomp_file() {
  local path="$1"
  python3 - "$path" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
data = p.read_bytes()
if data.endswith(b"\n"):
    p.write_bytes(data[:-1])
PY
}

secrets_try_get() {
  local backend="${1:-$(config_get secrets.backend prompt)}"
  [[ -n "$backend" ]] || backend=prompt
  local errfile
  NAS_BACKUP_PWFILE=$(mktemp -p "$(_password_tmpdir)" omaclone.XXXXXX)
  chmod 600 "$NAS_BACKUP_PWFILE"
  errfile=$(mktemp -p "$(_password_tmpdir)" omaclone.err.XXXXXX)
  if nas_backup_backend_run secrets "$backend" get >"$NAS_BACKUP_PWFILE" 2>"$errfile"; then
    password_chomp_file "$NAS_BACKUP_PWFILE"
    if [[ ! -s "$NAS_BACKUP_PWFILE" ]]; then
      password_cleanup
      rm -f "$errfile"
      NAS_BACKUP_SECRETS_ERRTEXT=""
      NAS_BACKUP_SECRETS_NOTICE=""
      return 1
    fi
    NAS_BACKUP_SECRETS_NOTICE=$(cat "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    NAS_BACKUP_SECRETS_ERRTEXT=""
    return 0
  else
    local rc=$?
    NAS_BACKUP_SECRETS_ERRTEXT=$(cat "$errfile" 2>/dev/null || true)
    rm -f "$errfile"
    password_cleanup
    return $rc
  fi
}

secrets_notice_is_update() {
  local text="${1:-}"
  [[ -n "$text" ]] || return 1
  local lower
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *new\ update\ available*|*\ update\ available*|*update\ available*) return 0 ;;
    *a\ new\ version*) return 0 ;;
    *pass-cli\ update*|*\"op\"\ update*|*\'op\'\ update*|*op\ update*) return 0 ;;
  esac
  return 1
}

secrets_has_update() {
  local backend="$1"
  local script_path
  script_path=$(nas_backup_backend_find secrets "$backend") || return 1
  grep -E '^[[:space:]]*update\)' "$script_path" >/dev/null 2>&1
}

password_offer_keyring_store() {
  local configured_backend="${1:-}"
  is_tty || return 0
  have gum || return 0
  [[ "$configured_backend" == "keyring" ]] && return 0
  local offer
  offer=$(config_get secrets.keyring_offer "")
  [[ "$offer" != "declined" && "$offer" != "stored" ]] || return 0
  [[ -n "${NAS_BACKUP_PWFILE:-}" && -s "${NAS_BACKUP_PWFILE:-}" ]] || return 0

  if ! nas_backup_backend_available secrets keyring; then
    if tui_confirm "Install GNOME Keyring support (libsecret) so omaclone can store the password?"; then
      nas_backup_backend_ensure secrets keyring || return 0
    else
      return 0
    fi
  fi

  local describe
  describe=$(nas_backup_backend_describe secrets "$configured_backend" | head -n 1)
  if tui_confirm "Store the restic password in the local keyring so omaclone doesn't need $describe on every run?"; then
    if nas_backup_backend_run secrets keyring put <"$NAS_BACKUP_PWFILE" 2>/dev/null; then
      config_set secrets.backend keyring
      config_set secrets.keyring_offer stored
      tui_note "Password stored in the keyring. Future runs will use it directly."
    else
      tui_error "Failed to store password in the keyring. Backend unchanged."
    fi
  else
    config_set secrets.keyring_offer declined
  fi
}

password_after_get_offers() {
  local configured_backend="${1:-}"
  is_tty && have gum || return 0
  if [[ -n "${NAS_BACKUP_SECRETS_NOTICE:-}" ]] \
     && secrets_notice_is_update "$NAS_BACKUP_SECRETS_NOTICE" \
     && secrets_has_update "$configured_backend"; then
    local describe
    describe=$(nas_backup_backend_describe secrets "$configured_backend" | head -n 1)
    if tui_confirm "A newer $describe is available. Install the update now?"; then
      nas_backup_backend_run secrets "$configured_backend" update || true
    fi
  fi
  password_offer_keyring_store "$configured_backend"
}

secrets_error_kind() {
  local backend="${1:-}" errtext="${2:-}"
  if [[ -z "$errtext" ]]; then
    printf '%s\n' "empty"
    return
  fi
  local lower
  lower=$(printf '%s' "$errtext" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *authenticated\ client*|*\ no\ session*|*not\ currently\ signed\ in*|*account\ is\ not\ signed\ in*|*is\ not\ signed\ in*)
      printf '%s\n' "need_login"; return ;;
  esac
  case "$lower" in
    *not\ found*|*could\ not\ find*|*no\ such\ item*|*item\ not\ found*|*vault\ not\ found*)
      printf '%s\n' "not_found"; return ;;
  esac
  printf '%s\n' "other"
}

secrets_has_unlock() {
  local backend="$1"
  local script_path
  script_path=$(nas_backup_backend_find secrets "$backend") || return 1
  grep -E '^[[:space:]]*unlock\)' "$script_path" >/dev/null 2>&1
}

password_deferred_note() {
  printf '%s\n' "omaclone: password not available yet. Run: omaclone setup" >&2
}

password_load() {
  password_cleanup
  local backend errtext kind picked picked_backend
  backend=$(config_get secrets.backend prompt)
  [[ -n "$backend" ]] || backend=prompt

  if ! is_tty || ! have gum; then
    if secrets_try_get "$backend"; then
      if [[ "${NAS_BACKUP_CLEAR_CLIPBOARD:-}" == "1" ]] && have wl-copy; then
        wl-copy --clear 2>/dev/null || true
      fi
      return 0
    fi
    password_cleanup
    if [[ -z "${NAS_BACKUP_SECRETS_ERRTEXT:-}" ]]; then
      printf 'omaclone: secret backend '\''%s'\'' returned an empty password\n' "$backend" >&2
    else
      printf 'omaclone: secret backend '\''%s'\'' failed to provide a password\n' "$backend" >&2
    fi
    return 1
  fi

  while true; do
    if secrets_try_get "$backend"; then
      if [[ "${NAS_BACKUP_CLEAR_CLIPBOARD:-}" == "1" ]] && have wl-copy; then
        wl-copy --clear 2>/dev/null || true
      fi
      password_after_get_offers "$backend"
      return 0
    fi
    errtext="${NAS_BACKUP_SECRETS_ERRTEXT:-}"
    kind=$(secrets_error_kind "$backend" "$errtext")
    if [[ -z "$errtext" ]]; then
      errtext="secret backend '$backend' returned an empty password"
    fi
    if declare -F tui_error >/dev/null; then
      tui_error "$errtext"
    else
      printf '%s\n' "$errtext" >&2
    fi
    local options=("Retry now")
    if secrets_has_unlock "$backend"; then
      options+=("Sign in to the password manager")
    fi
    if [[ -n "${NAS_BACKUP_SECRETS_ERRTEXT:-}" ]] \
       && secrets_notice_is_update "$errtext" \
       && secrets_has_update "$backend"; then
      options+=("Install the available update")
    fi
    options+=("Change vault / item / field")
    options+=("Switch password source")
    options+=("Paste the password this time")
    options+=("Continue later")
    picked=$(printf '%s\n' "${options[@]}" | gum choose --header="Could not get the restic password") || {
      password_cleanup
      die "aborted"
    }
    case "$picked" in
      "Retry now") continue ;;
      "Install the available update")
        nas_backup_backend_run secrets "$backend" update || true
        continue
        ;;
      "Sign in to the password manager")
        nas_backup_backend_run secrets "$backend" unlock || true
        ;;
      "Change vault / item / field")
        nas_backup_backend_run secrets "$backend" setup
        ;;
      "Switch password source")
        picked_backend=$(nas_backup_backend_choose_all secrets "How should omaclone get the restic password?") || continue
        nas_backup_backend_ensure secrets "$picked_backend" || continue
        nas_backup_backend_run secrets "$picked_backend" setup
        backend=$picked_backend
        ;;
      "Paste the password this time")
        if secrets_try_get prompt; then
          if [[ "${NAS_BACKUP_CLEAR_CLIPBOARD:-}" == "1" ]] && have wl-copy; then
            wl-copy --clear 2>/dev/null || true
          fi
          password_after_get_offers "$backend"
          return 0
        fi
        ;;
      "Continue later")
        password_cleanup
        password_deferred_note
        return 1
        ;;
    esac
  done
}

generate_restic_password() {
  if have openssl; then
    openssl rand -base64 32
  else
    python3 -c 'import secrets,base64; print(base64.b64encode(secrets.token_bytes(32)).decode())'
  fi
}

restic_repo() {
  local repo mp uuid live
  repo=$(config_get restic.repo)
  [[ -n "$repo" ]] || return 0
  uuid=$(config_get transport.uuid "")
  if [[ -z "$uuid" ]]; then
    printf '%s\n' "$repo"
    return 0
  fi
  live=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$uuid" 2>/dev/null | head -n 1)
  if [[ -n "$live" ]]; then
    mp=$(config_get transport.mountpoint "")
    repo=$(map_restic_repo_onto_mount "$repo" "$mp" "$live") || { printf '%s\n' "$repo"; return 0; }
  fi
  printf '%s\n' "$repo"
}

transport_prepare_env() {
  local backend
  backend=$(config_get transport.backend)
  [[ -n "$backend" ]] || return 0
  NAS_BACKUP_ENVFILE=$(mktemp -p "$(_password_tmpdir)" omaclone.env.XXXXXX)
  chmod 600 "$NAS_BACKUP_ENVFILE"
  : >"$NAS_BACKUP_ENVFILE"
  export NAS_BACKUP_ENVFILE
  if ! nas_backup_backend_run transport "$backend" pre-restic 2>/dev/null; then
    die "transport '$backend' failed to prepare restic credentials"
  fi
}

restic_exec() {
  local repo
  repo=$(restic_repo)
  [[ -n "$repo" ]] || die "restic.repo is not set; run: omaclone setup"
  [[ -n "$NAS_BACKUP_PWFILE" && -e "$NAS_BACKUP_PWFILE" ]] || die "password file missing"
  case "$repo" in
    s3:*|sftp:*) ;;
    *)
      if ! stat "$repo/config" >/dev/null 2>&1; then
        local _stat_err
        _stat_err=$(stat "$repo/config" 2>&1) || true
        case "${_stat_err,,}" in
          *input/output\ error*|*\ i/o\ error*)
            die "clone location is not readable: $repo (I/O error — the disk may have remounted read-only)"
            ;;
        esac
      fi
      ;;
  esac
  (
    if [[ -n "${NAS_BACKUP_ENVFILE:-}" && -s "$NAS_BACKUP_ENVFILE" ]]; then
      set -a
      source "$NAS_BACKUP_ENVFILE"
      set +a
    fi
    restic --password-file "$NAS_BACKUP_PWFILE" --repo "$repo" "$@"
  )
}

write_last_result() {
  local status="$1"
  local message="${2:-}"
  local reason="${3:-}"
  mkdir -p "$NAS_BACKUP_STATE_DIR"
  local loc_id=""
  if [[ -n "${OMACLONE_LOCATIONS_LOADED:-}" ]]; then
    loc_id=$(location_active_id 2>/dev/null || true)
  fi
  python3 - "$NAS_BACKUP_STATE_DIR/last-result.json" \
            "${NAS_BACKUP_STATE_DIR}/last-result-${loc_id}.json" \
            "$status" "$message" "$loc_id" "$reason" <<'PY'
import json, sys, time
result_path, per_loc_path, status, message, loc, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
data = {
    "status": status,
    "message": message,
    "unix": int(time.time()),
    "location": loc,
    "reason": reason,
}
import os, tempfile
from pathlib import Path

def atomic_write(path, payload):
    path = Path(path)
    if not path.parent.as_posix() or path.name.endswith("last-result-.json"):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

atomic_write(result_path, data)
if per_loc_path:
    atomic_write(per_loc_path, data)
PY
}

restic_summarize_fail() {
  local rc="$1"
  local errfile="${2:-}"
  python3 - "$rc" "$errfile" <<'PY'
import re, sys
from pathlib import Path
rc = sys.argv[1]
path = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
text = ""
if path and path.is_file():
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
secret = re.compile(r"(password|secret|token|aws_|op://|pass-cli|Authorization)\S*", re.I)
lines = []
for raw in text.splitlines():
    line = secret.sub("***", raw).strip()
    if not line:
        continue
    low = line.lower()
    if any(k in low for k in ("fatal", "error", "i/o", "input/output", "permission", "no space", "wrong password", "no key", "locked", "timeout", "connection")):
        lines.append(line)
snippet = " ".join(lines[-2:])[:180].strip()
low = (snippet or text).lower()
if "wrong password" in low or "no key found" in low:
    print("Clone failed: restic password was rejected")
elif "input/output" in low or "i/o error" in low:
    print("Clone location is not readable (I/O error)")
elif "no space" in low:
    print("Clone failed: no space left on the clone location")
elif "permission denied" in low:
    print("Clone failed: permission denied on the clone location")
elif snippet:
    print(snippet)
else:
    print(f"Clone failed (restic exited {rc})")
PY
}

write_issue_ack() {
  mkdir -p "$NAS_BACKUP_STATE_DIR"
  local loc_id last_unix=0
  loc_id=""
  if [[ -n "${OMACLONE_LOCATIONS_LOADED:-}" ]]; then
    loc_id=$(location_active_id 2>/dev/null || true)
  fi
  if [[ -f "$NAS_BACKUP_STATE_DIR/last-result.json" ]]; then
    last_unix=$(jq -r '.unix // 0' "$NAS_BACKUP_STATE_DIR/last-result.json" 2>/dev/null || echo 0)
  fi
  python3 - "$NAS_BACKUP_STATE_DIR/issue-ack.json" "$loc_id" "$last_unix" <<'PY'
import json, sys, time
path, loc, last_unix = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    last_unix = int(last_unix or 0)
except ValueError:
    last_unix = 0
data = {"unix": int(time.time()), "location": loc, "lastUnix": last_unix}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}

issue_is_disconnect() {
  local msg="${1:-}"
  local backend="${2:-}"
  case "$backend" in
    s3|sftp) return 1 ;;
  esac
  local lower
  lower=$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *"not connected"*|*"plug in"*|*"not mounted"*)
      return 0 ;;
  esac
  return 1
}

issue_is_password_skip() {
  local reason="${1:-}"
  local msg="${2:-}"
  [[ "$reason" == password ]] && return 0
  local lower
  lower=$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    *password\ is\ not\ available*|*unlock\ keyring*|*password\ manager*|*prompt\ backend*)
      return 0 ;;
  esac
  return 1
}

keyring_retry_active() {
  [[ "${OMACLONE_SKIP_SYSTEMD:-}" == 1 ]] && return 1
  systemctl --user is-active --quiet omaclone-keyring-retry.service 2>/dev/null
}

schedule_keyring_retry() {
  [[ "${OMACLONE_SKIP_SYSTEMD:-}" == 1 ]] && return 0
  local unit="$HOME/.config/systemd/user/omaclone-keyring-retry.service"
  local src="$NAS_BACKUP_ROOT/systemd/omaclone-keyring-retry.service"
  if [[ ! -f "$unit" && -f "$src" ]]; then
    mkdir -p "$(dirname "$unit")"
    cp "$src" "$unit"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  [[ -f "$unit" ]] || return 0
  systemctl --user start omaclone-keyring-retry.service 2>/dev/null || true
}

stop_keyring_retry() {
  [[ "${OMACLONE_SKIP_SYSTEMD:-}" == 1 ]] && return 0
  systemctl --user stop omaclone-keyring-retry.service 2>/dev/null || true
}

issue_is_acked() {
  local last_unix="${1:-0}" loc_id="${2:-}"
  local ack="$NAS_BACKUP_STATE_DIR/issue-ack.json"
  [[ -f "$ack" ]] || return 1
  python3 - "$ack" "$last_unix" "$loc_id" <<'PY'
import json, sys
from pathlib import Path
ack_path, last_unix, loc = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.loads(Path(ack_path).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
try:
    ack_unix = int(data.get("unix") or 0)
    last_unix = int(last_unix or 0)
except ValueError:
    raise SystemExit(1)
ack_loc = str(data.get("location") or "")
if ack_unix < last_unix:
    raise SystemExit(1)
if ack_loc and loc and ack_loc != loc:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

notify() {
  local title="$1"
  local body="${2:-}"
  local urgency="${3:-normal}"
  local backend
  backend=$(config_get notify.backend notify-send)
  nas_backup_backend_run notify "$backend" send "$title" "$body" "$urgency" 2>/dev/null || true
}

home_foreign_mounts() {
  local t
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    case "$t" in
      "$HOME"/*) printf '%s\n' "${t#"$HOME"/}" ;;
    esac
  done < <(findmnt -n -o TARGET -l 2>/dev/null || true)
}

etc_rel_ok() {
  local rel="$1"
  [[ -n "$rel" && "$rel" != \#* ]] || return 1
  case "$rel" in
    /*|*..*) return 1 ;;
  esac
  local base="${rel%%/*}"
  case "$base" in
    fstab|crypttab|hostname|hosts|shadow|gshadow|machine-id|mkinitcpio.conf|cryptsetup-keys.d)
      return 1 ;;
  esac
  case "$rel" in
    *limine*|*grub*|NetworkManager/*|ssh/ssh_host_*|sudoers|sudoers.d/*)
      return 1 ;;
  esac
  return 0
}

fresh_home() {
  [[ -d "$NAS_BACKUP_STATE_DIR/staging" ]] && return 1
  [[ -d "$HOME/.local/share/nas-backup/staging" ]] && return 1
  local du_args=("$HOME")
  local rel
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    du_args+=(--exclude="$HOME/$rel")
  done < <(home_foreign_mounts)
  local size
  size=$(du -sm "${du_args[@]}" 2>/dev/null | awk '{print $1}')
  [[ "${size:-0}" -lt 500 ]]
}

match_hardware_pkg() {
  local pkg="$1"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$pkg" in
      $line) return 0 ;;
    esac
  done <"$NAS_BACKUP_ROOT/config/hardware-packages.txt"
  return 1
}

match_denied_unit() {
  local unit="$1"
  local base="${unit%.service}"
  base="${base%.timer}"
  local line
  local deny="$NAS_BACKUP_ROOT/config/user-units.deny"
  [[ -f "$deny" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    case "$unit" in
      $line) return 0 ;;
    esac
    case "$base" in
      $line) return 0 ;;
    esac
  done <"$deny"
  return 1
}

split_package_lists() {
  local dest="$1"
  mkdir -p "$dest"
  : >"$dest/pkglist-identity.txt"
  : >"$dest/pkglist-hardware.txt"
  : >"$dest/pkglist-aur.txt"
  local pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if match_hardware_pkg "$pkg"; then
      printf '%s\n' "$pkg" >>"$dest/pkglist-hardware.txt"
    else
      printf '%s\n' "$pkg" >>"$dest/pkglist-identity.txt"
    fi
  done < <(pacman -Qqe 2>/dev/null || true)
  pacman -Qqem 2>/dev/null >"$dest/pkglist-aur.txt" || true
}

staging_file() {
  local name="$1"
  local p
  for p in \
    "$HOME/.local/share/omaclone/staging/$name" \
    "$HOME/.local/share/omarchy-backup/staging/$name" \
    "$HOME/.local/share/nas-backup/staging/$name" \
    "$NAS_BACKUP_STAGING/$name"
  do
    if [[ -e "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

require_gum() {
  if have gum; then return 0; fi
  source "$NAS_BACKUP_ROOT/scripts/deps.sh" 2>/dev/null || true
  deps_ensure_pacman gum && return 0
  die "gum is required for the TUI (it ships with Omarchy)"
}

require_core_deps() {
  source "$NAS_BACKUP_ROOT/scripts/deps.sh" 2>/dev/null || true
  local missing=() pkg
  for pkg in "${_CORE_PACMAN_PKGS[@]}"; do
    have "$pkg" || missing+=("$pkg")
  done
  if ((${#missing[@]} > 0)); then
    printf 'omaclone: installing %s …\n' "${missing[*]}" >&2
    deps_ensure_pacman_list "${missing[@]}"
  fi
}

require_restore_deps() {
  source "$NAS_BACKUP_ROOT/scripts/deps.sh" 2>/dev/null || true
  local missing=() pkg
  for pkg in restic jq rsync; do
    have "$pkg" || missing+=("$pkg")
  done
  if ((${#missing[@]} > 0)); then
    printf 'omaclone: installing %s …\n' "${missing[*]}" >&2
    deps_ensure_pacman_list "${missing[@]}"
  fi
}

TRANSPORT_SECRET_SERVICE="omaclone"

transport_secret_put() {
  local attr="$1"
  python3 "$NAS_BACKUP_ROOT/scripts/keyring_store.py" put "$attr" --label "omaclone $attr"
}

transport_secret_get() {
  local attr="$1"
  python3 "$NAS_BACKUP_ROOT/scripts/keyring_store.py" get "$attr"
}

transport_secret_prompt_and_store() {
  local attr="$1"
  local placeholder="$2"
  require_gum
  local value
  value=$(gum input --password --placeholder "$placeholder" </dev/tty) || return 1
  [[ -n "$value" ]] || return 1
  printf '%s' "$value" | transport_secret_put "$attr"
  unset value
}

write_recovery_card() {
  local dest="${1:-$NAS_BACKUP_STATE_DIR/RECOVERY.md}"
  mkdir -p "$(dirname "$dest")"
  local profile transport uri repo mountpoint vendor endpoint bucket
  profile=$(config_get destination.profile)
  vendor=$(config_get destination.vendor)
  transport=$(config_get transport.backend)
  uri=$(config_get transport.uri)
  mountpoint=$(config_get transport.mountpoint)
  repo=$(config_get restic.repo)
  endpoint=$(config_get transport.endpoint)
  bucket=$(config_get transport.bucket)
  local disk_uuid
  disk_uuid=$(config_get transport.uuid)
  local restore_hint="/path/to/clone/restore"
  if [[ -n "$mountpoint" ]]; then
    restore_hint="$(omaclone_kit_dir "$mountpoint")/restore"
  fi
  cat >"$dest" <<EOF
# Omaclone recovery

This card has **no passwords and no access keys**.

- Destination: ${profile:-unknown}${vendor:+ ($vendor)}
- Transport: ${transport:-unknown}
- Locator: ${uri:-${endpoint:+$endpoint $bucket}${disk_uuid:+UUID $disk_uuid}${mountpoint:+ $mountpoint}}
- Restic repo: ${repo:-unset}

## New computer

1. Install Omarchy (use the same username if you can).
2. Restore using whichever you still have:

**USB / extra disk / NAS share** — plug in or mount the backup location, then:

    ${restore_hint}

**Cloud, or you only have this plugin** — after Omarchy is installed:

    omarchy plugin add ${PLUGIN_REPO_URL} --enable
    ~/.config/omarchy/plugins/omaclone.plugin/scripts/omaclone restore

The restic repository password lives in your password manager or keyring, not here.
EOF
  chmod 600 "$dest"
  printf '%s\n' "$dest"
}
