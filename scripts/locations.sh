if [[ -n "${OMACLONE_LOCATIONS_LOADED:-}" ]]; then
  return 0
fi
OMACLONE_LOCATIONS_LOADED=1

_location_keys=(backend uri mountpoint repo label profile vendor uuid device fstype mode schedule endpoint bucket prefix region tls username port host remote_path preset role_arn lookup)

location_ids() {
  local raw id
  raw=$(config_get locations.ids)
  raw="${raw//,/ }"
  local -A seen=()
  for id in $raw; do
    [[ -n "$id" ]] || continue
    [[ -n "${seen[$id]:-}" ]] && continue
    seen[$id]=1
    printf '%s\n' "$id"
  done
}

location_active_id() {
  config_get locations.active
}

location_get() {
  local id="$1" key="$2" default="${3:-}"
  config_get "locations.${id}.${key}" "$default"
}

location_set() {
  config_set "locations.${1}.${2}" "$3"
}

location_has() {
  local want="$1" id
  while IFS= read -r id; do
    [[ "$id" == "$want" ]] && return 0
  done < <(location_ids)
  return 1
}

_location_forgotten_add() {
  local token="$1" existing t
  [[ -n "$token" ]] || return 0
  existing=$(config_get locations.forgotten)
  if [[ -n "$existing" ]]; then
    local -a parts=()
    IFS='|' read -ra parts <<< "$existing"
    for t in "${parts[@]}"; do
      [[ "$t" == "$token" ]] && return 0
    done
    config_set locations.forgotten "${existing}|${token}"
  else
    config_set locations.forgotten "$token"
  fi
}

_location_forgotten_unmark() {
  local existing t new="" skip want
  existing=$(config_get locations.forgotten)
  [[ -n "$existing" ]] || return 0
  local -a parts=()
  IFS='|' read -ra parts <<< "$existing"
  for t in "${parts[@]}"; do
    [[ -z "$t" ]] && continue
    skip=0
    for want in "$@"; do
      if [[ -n "$want" && "$t" == "$want" ]]; then
        skip=1
        break
      fi
    done
    ((skip)) && continue
    if [[ -n "$new" ]]; then
      new="${new}|${t}"
    else
      new="$t"
    fi
  done
  config_set locations.forgotten "$new"
}

location_drop() {
  local id="$1" i out=() active uuid mp uri key
  [[ -n "$id" ]] || return 1
  location_has "$id" || return 1
  uuid=$(location_get "$id" uuid)
  mp=$(location_get "$id" mountpoint)
  uri=$(location_get "$id" uri)
  _location_forgotten_add "$uuid"
  _location_forgotten_add "$mp"
  _location_forgotten_add "$uri"
  [[ -n "$mp" ]] && _location_forgotten_add "${mp}/omaclone"
  while IFS= read -r i; do
    [[ -n "$i" && "$i" != "$id" ]] && out+=("$i")
  done < <(location_ids)
  if ((${#out[@]})); then
    local IFS=,
    config_set locations.ids "${out[*]}"
  else
    config_set locations.ids ""
    for key in backend uri mountpoint uuid device fstype mode endpoint bucket prefix region tls username port host remote_path preset role_arn lookup; do
      config_set "transport.${key}" ""
    done
    config_set restic.repo ""
    if [[ "${OMACLONE_SKIP_SYSTEMD:-}" != 1 ]]; then
      systemctl --user disable --now omaclone.timer 2>/dev/null || true
      systemctl --user disable --now omaclone-prune.timer 2>/dev/null || true
    fi
    config_set locations.migrated 1
  fi
  config_drop "locations.$id"
  rm -f "$NAS_BACKUP_STATE_DIR/repo-stats-${id}.json" 2>/dev/null || true
  active=$(location_active_id)
  if [[ "$active" == "$id" ]]; then
    if ((${#out[@]})); then
      location_activate "${out[0]}"
    else
      config_set locations.active ""
    fi
  fi
}

location_forget_absent_disks() {
  local id backend uuid live kit
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    backend=$(location_get "$id" backend)
    [[ "$backend" == disk ]] || continue
    uuid=$(location_get "$id" uuid)
    if [[ -z "$uuid" || ! -e "/dev/disk/by-uuid/$uuid" ]]; then
      continue
    fi
    live=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$uuid" 2>/dev/null | head -n 1)
    [[ -n "$live" ]] || continue
    kit=$(omaclone_kit_dir "$live")
    if [[ ! -f "$kit/repo/config" && ! -d "$kit/repo/snapshots" && ! -f "$kit/.omaclone-bootstrap" && ! -f "$kit/restore" ]]; then
      location_drop "$id"
    fi
  done < <(location_ids)
}

location_ids_add() {
  local id="$1" i out=()
  [[ -n "$id" ]] || return 0
  while IFS= read -r i; do
    [[ -z "$i" ]] && continue
    [[ "$i" == "$id" ]] && return 0
    out+=("$i")
  done < <(location_ids)
  out+=("$id")
  local IFS=,
  config_set locations.ids "${out[*]}"
}

location_drop_orphans() {
  local section id ids_csv
  ids_csv=",$(config_get locations.ids),"
  ids_csv="${ids_csv// /,}"
  while IFS= read -r section; do
    [[ "$section" == locations.* ]] || continue
    id="${section#locations.}"
    [[ -n "$id" ]] || continue
    case ",$ids_csv," in
      *",$id,"*) continue ;;
    esac
    config_drop "$section"
  done < <(python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" dump 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
}

location_ids_compact() {
  local id backend uuid active current compact=""
  local -A keep_uuid=()
  local out=()
  current=$(config_get locations.ids)
  active=$(location_active_id)
  location_drop_orphans
  if [[ -n "$active" ]]; then
    backend=$(location_get "$active" backend)
    uuid=$(location_get "$active" uuid)
    if [[ -n "$backend" && -n "$uuid" ]]; then
      keep_uuid["$uuid"]="$active"
    fi
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    backend=$(location_get "$id" backend)
    [[ -n "$backend" ]] || continue
    uuid=$(location_get "$id" uuid)
    if [[ -n "$uuid" ]]; then
      if [[ -n "${keep_uuid[$uuid]:-}" && "${keep_uuid[$uuid]}" != "$id" ]]; then
        continue
      fi
      keep_uuid["$uuid"]="$id"
    fi
    out+=("$id")
  done < <(location_ids)
  if ((${#out[@]})); then
    local IFS=,
    compact="${out[*]}"
  fi
  if [[ -z "$compact" && -n "$current" ]]; then
    return 0
  fi
  [[ "$current" == "$compact" ]] && return 0
  config_set locations.ids "$compact"
}

location_find_id_by_uuid() {
  local want="$1" id uuid
  [[ -n "$want" ]] || return 1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    uuid=$(location_get "$id" uuid)
    if [[ "$uuid" == "$want" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done < <(location_ids)
  return 1
}

location_slug() {
  local raw="${1:-loc}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
  raw="${raw#-}"
  raw="${raw%-}"
  [[ -n "$raw" ]] || raw=loc
  local candidate="$raw" n=2
  while location_has "$candidate"; do
    candidate="${raw}-${n}"
    n=$((n + 1))
  done
  printf '%s\n' "$candidate"
}

location_default_schedule() {
  local backend="${1:-}"
  local mode="${2:-}"
  case "$backend" in
    disk)
      # Hot extra disk (configured mountpoint / NVMe) can run the timer.
      # USB/cold stays off until `omaclone location schedule on`.
      if [[ "$mode" == hot ]]; then
        printf '%s\n' on
      else
        printf '%s\n' off
      fi
      ;;
    *) printf '%s\n' on ;;
  esac
}

location_default_label() {
  local backend="${1:-}"
  local profile="${2:-}"
  local mode="${3:-}"
  local preset="${4:-}"
  case "$backend" in
    disk)
      if [[ "$mode" == cold ]]; then
        printf '%s\n' "USB"
      else
        printf '%s\n' "Extra disk"
      fi
      ;;
    nfs|cifs|sftp) printf '%s\n' "NAS" ;;
    s3)
      [[ -n "$preset" ]] || preset=$(config_get transport.preset 2>/dev/null || true)
      case "$preset" in
        aws) printf '%s\n' "AWS S3" ;;
        r2) printf '%s\n' "Cloudflare R2" ;;
        wasabi) printf '%s\n' "Wasabi" ;;
        b2) printf '%s\n' "Backblaze B2" ;;
        minio) printf '%s\n' "MinIO" ;;
        *) printf '%s\n' "Cloud (S3)" ;;
      esac
      ;;
    local) printf '%s\n' "Local path" ;;
    *) printf '%s\n' "${profile:-$backend}" ;;
  esac
}

_location_field_keys() {
  printf '%s\n' uri mountpoint uuid device fstype mode endpoint bucket prefix region tls username port host remote_path preset role_arn lookup
}

_location_backend_field_keys() {
  case "${1:-}" in
    nfs) printf '%s\n' uri mountpoint ;;
    cifs) printf '%s\n' uri mountpoint username ;;
    sftp) printf '%s\n' host port username remote_path ;;
    disk) printf '%s\n' uuid device fstype mode mountpoint ;;
    s3) printf '%s\n' endpoint bucket prefix region tls preset role_arn lookup ;;
    local) printf '%s\n' mountpoint ;;
  esac
}

location_profile_for_backend() {
  case "${1:-}" in
    nfs|cifs|sftp) printf '%s\n' nas ;;
    disk) printf '%s\n' disk ;;
    s3) printf '%s\n' cloud ;;
    local) printf '%s\n' local ;;
    *) printf '%s\n' "${2:-}" ;;
  esac
}

location_destination_lock_path() {
  printf '%s\n' "$NAS_BACKUP_STATE_DIR/destination.lock"
}

location_destination_edit_begin() {
  mkdir -p "$NAS_BACKUP_STATE_DIR"
  printf '%s\n' "$$" >"$(location_destination_lock_path)"
}

location_destination_edit_end() {
  local path pid
  path=$(location_destination_lock_path)
  [[ -f "$path" ]] || return 0
  pid=$(head -n 1 "$path" 2>/dev/null || true)
  if [[ "$pid" == "$$" ]]; then
    rm -f "$path"
  fi
}

location_destination_edit_held() {
  local path pid
  path=$(location_destination_lock_path)
  [[ -f "$path" ]] || return 1
  pid=$(head -n 1 "$path" 2>/dev/null || true)
  [[ -n "$pid" ]] || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/$pid" ]]
}

location_reset_live_transport() {
  local backend="${1:-}" key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    config_set "transport.${key}" ""
  done < <(_location_field_keys)
  config_set restic.repo ""
  if [[ -n "$backend" ]]; then
    config_set transport.backend "$backend"
  fi
}

_location_wake() {
  local mp="${1:-}"
  [[ -n "$mp" ]] || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 8 stat "$mp" >/dev/null 2>&1 || true
  else
    stat "$mp" >/dev/null 2>&1 || true
  fi
}

_location_tcp_up() {
  local host="$1" port="${2:-22}"
  [[ -n "$host" ]] || return 1
  python3 -c '
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
try:
    s = socket.create_connection((host, port), 2)
    s.close()
except OSError:
    sys.exit(1)
' "$host" "$port" 2>/dev/null
}

location_connected() {
  local id="$1"
  local backend mode uuid mp repo host port fstype
  backend=$(location_get "$id" backend)
  mode=$(location_get "$id" mode)
  uuid=$(location_get "$id" uuid)
  mp=$(location_get "$id" mountpoint)
  repo=$(location_get "$id" repo)
  case "$backend" in
    disk)
      [[ -n "$uuid" && -e "/dev/disk/by-uuid/$uuid" ]]
      ;;
    nfs)
      [[ -n "$mp" ]] || return 1
      _location_wake "$mp"
      findmnt -n -t nfs,nfs4 "$mp" >/dev/null 2>&1
      ;;
    cifs)
      [[ -n "$mp" ]] || return 1
      _location_wake "$mp"
      findmnt -n -t cifs "$mp" >/dev/null 2>&1
      ;;
    local)
      [[ -n "$repo" && -d "$(dirname "$repo")" ]] || return 1
      if [[ -n "$mp" ]] && findmnt -n "$mp" >/dev/null 2>&1; then
        _location_wake "$mp"
        fstype=$(findmnt -n -o FSTYPE "$mp" 2>/dev/null | awk '$1 != "" && $1 != "autofs" { print; exit }')
        [[ -n "$fstype" ]]
        return
      fi
      case "$mp" in
        /mnt/*|/media/*|/run/media/*) return 1 ;;
      esac
      return 0
      ;;
    sftp)
      host=$(location_get "$id" host)
      port=$(location_get "$id" port 22)
      _location_tcp_up "$host" "${port:-22}"
      ;;
    s3)
      return 0
      ;;
    *)
      [[ -n "$mp" && -e "$mp" ]]
      ;;
  esac
}

location_prepare_mount() {
  local id="$1"
  local backend mp prev rc=0
  backend=$(location_get "$id" backend)
  mp=$(location_get "$id" mountpoint)
  _location_wake "$mp"
  location_connected "$id" && return 0
  case "$backend" in
    nfs|cifs|disk|local) ;;
    *) return 1 ;;
  esac
  prev=$(location_active_id)
  if [[ -z "$prev" || "$prev" == "$id" ]]; then
    nas_backup_backend_run transport "$backend" mount || return 1
    location_connected "$id"
    return
  fi
  location_apply_transport "$id"
  nas_backup_backend_run transport "$backend" mount || rc=$?
  location_apply_transport "$prev"
  (( rc == 0 )) || return 1
  location_connected "$id"
}

location_save_current() {
  local id="$1"
  local backend mode label schedule profile key
  [[ -n "$id" ]] || die "location id is empty; run: omaclone setup"
  backend=$(config_get transport.backend)
  [[ -n "$backend" ]] || die "no transport configured"
  local uuid mp uri
  uuid=$(config_get transport.uuid)
  mp=$(config_get transport.mountpoint)
  uri=$(config_get transport.uri)
  _location_forgotten_unmark "$uuid" "$mp" "${mp:+$mp/omaclone}" "$uri"
  config_set locations.migrated 1
  mode=$(config_get transport.mode)
  if [[ "$backend" == disk && -z "$mode" ]]; then
    if [[ -n "$mp" ]]; then
      mode=hot
    else
      mode=cold
    fi
    config_set transport.mode "$mode"
  fi
  profile=$(location_profile_for_backend "$backend" "$(config_get destination.profile)")
  label="${2:-$(location_default_label "$backend" "$profile" "$mode" "$(config_get transport.preset)")}"
  schedule="${3:-$(location_default_schedule "$backend" "$mode")}"
  location_set "$id" backend "$backend"
  location_set "$id" repo "$(config_get restic.repo)"
  location_set "$id" label "$label"
  location_set "$id" profile "$profile"
  if [[ "$profile" == nas ]]; then
    location_set "$id" vendor "$(config_get destination.vendor)"
  else
    location_set "$id" vendor ""
  fi
  location_set "$id" schedule "$schedule"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    location_set "$id" "$key" ""
  done < <(_location_field_keys)
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    location_set "$id" "$key" "$(config_get "transport.$key")"
  done < <(_location_backend_field_keys "$backend")
  location_ids_add "$id"
}

location_apply_transport() {
  local id="$1"
  local backend repo profile key
  backend=$(location_get "$id" backend)
  repo=$(location_get "$id" repo)
  [[ -n "$backend" && -n "$repo" ]] || die "unknown location: $id"
  config_set transport.backend "$backend"
  config_set restic.repo "$repo"
  profile=$(location_profile_for_backend "$backend" "$(location_get "$id" profile)")
  config_set destination.profile "$profile"
  if [[ "$profile" == nas ]]; then
    config_set destination.vendor "$(location_get "$id" vendor)"
  else
    config_set destination.vendor ""
  fi
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    config_set "transport.${key}" ""
  done < <(_location_field_keys)
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    config_set "transport.${key}" "$(location_get "$id" "$key")"
  done < <(_location_backend_field_keys "$backend")
  config_set locations.active "$id"
}

location_schedule_apply() {
  local id="${1:-$(location_active_id)}"
  local schedule
  schedule=$(location_get "$id" schedule on)
  if [[ "${OMACLONE_SKIP_SYSTEMD:-}" == 1 ]]; then
    return 0
  fi
  if [[ ! -f "$HOME/.config/systemd/user/omaclone.timer" ]]; then
    return 0
  fi
  systemctl --user daemon-reload 2>/dev/null || true
  if [[ "$schedule" == on ]]; then
    systemctl --user enable --now omaclone.timer 2>/dev/null || true
    systemctl --user enable --now omaclone-prune.timer 2>/dev/null || true
    log "automatic clones enabled for location '$id'"
  else
    systemctl --user disable --now omaclone.timer 2>/dev/null || true
    systemctl --user disable --now omaclone-prune.timer 2>/dev/null || true
    log "automatic clones disabled for location '$id'"
  fi
}

location_activate() {
  local id="$1"
  location_has "$id" || die "unknown location: $id"
  location_apply_transport "$id"
  location_schedule_apply "$id"
}

location_sync_active() {
  local id backend live want
  if location_destination_edit_held; then
    return 0
  fi
  id=$(location_active_id)
  [[ -n "$id" ]] || return 0
  backend=$(location_get "$id" backend)
  [[ -n "$backend" ]] || return 0
  want=$(location_get "$id" repo)
  [[ -n "$want" ]] || return 0
  live=$(config_get restic.repo)
  if [[ "$live" == "$want" && "$(config_get transport.backend)" == "$backend" ]]; then
    return 0
  fi
  location_apply_transport "$id"
}

migrate_locations() {
  location_ids_compact
  [[ -n "$(config_get locations.ids)" ]] && return 0
  [[ "$(config_get locations.migrated)" == 1 ]] && return 0

  local backend repo
  backend=$(config_get transport.backend)
  repo=$(config_get restic.repo)
  [[ -n "$backend" && -n "$repo" ]] || return 0
  local mode id leftover
  mode=$(config_get transport.mode)
  leftover=$(config_get transport.uri)
  case "$backend" in
    disk) id=usb ;;
    nfs|cifs|sftp) id=nas ;;
    s3) id=cloud ;;
    *) id=local ;;
  esac
  location_save_current "$id"
  config_set locations.active "$id"
  if [[ "$backend" == disk && "$leftover" == *:* && "$leftover" != //* ]]; then
    location_set nas backend nfs
    location_set nas uri "$leftover"
    location_set nas mountpoint /mnt/omaclone
    location_set nas repo /mnt/omaclone/omaclone/repo
    location_set nas label NAS
    location_set nas profile nas
    location_set nas schedule on
    location_ids_add nas
  fi
  config_set locations.migrated 1
}

location_list_json() {
  location_forget_absent_disks
  python3 - "$NAS_BACKUP_CONFIG" "$NAS_BACKUP_ROOT" <<'PY'
import json, os, subprocess, sys
from pathlib import Path

config = Path(sys.argv[1])
root = Path(sys.argv[2])

import importlib.util
_spec = importlib.util.spec_from_file_location("omaclone_config", str(root / "scripts" / "config.py"))
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

def load_toml(path: Path) -> dict:
    return _mod.load(path)

def connected(loc: dict) -> bool:
    backend = loc.get("backend", "")
    uuid = loc.get("uuid", "")
    mp = loc.get("mountpoint", "")
    repo = loc.get("repo", "")
    if backend == "disk":
        return bool(uuid) and Path(f"/dev/disk/by-uuid/{uuid}").exists()
    if backend == "nfs":
        if not mp:
            return False
        try:
            os.stat(mp)
        except OSError:
            pass
        try:
            subprocess.check_call(["findmnt", "-n", "-t", "nfs,nfs4", mp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except (OSError, subprocess.CalledProcessError):
            return False
    if backend == "cifs":
        if not mp:
            return False
        try:
            os.stat(mp)
        except OSError:
            pass
        try:
            subprocess.check_call(["findmnt", "-n", "-t", "cifs", mp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except (OSError, subprocess.CalledProcessError):
            return False
    if backend == "local":
        if not repo or not Path(repo).parent.is_dir():
            return False
        if mp:
            try:
                subprocess.check_call(["findmnt", "-n", mp], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except (OSError, subprocess.CalledProcessError):
                return not (mp.startswith("/mnt/") or mp.startswith("/media/") or mp.startswith("/run/media/"))
            try:
                os.stat(mp)
            except OSError:
                pass
            try:
                out = subprocess.check_output(["findmnt", "-n", "-o", "FSTYPE", mp], text=True, stderr=subprocess.DEVNULL)
            except (OSError, subprocess.CalledProcessError):
                return False
            return any(line.strip() and line.strip() != "autofs" for line in out.splitlines())
        return True
    if backend == "sftp":
        host = loc.get("host", "")
        if not host:
            return False
        try:
            port = int(loc.get("port") or 22)
        except (TypeError, ValueError):
            port = 22
        try:
            import socket
            with socket.create_connection((host, port), 2):
                return True
        except OSError:
            return False
    if backend == "s3":
        return True
    return bool(mp) and Path(mp).exists()

def live_targets(uuid: str):
    if not uuid:
        return []
    src = f"/dev/disk/by-uuid/{uuid}"
    if not Path(src).exists():
        return []
    try:
        out = subprocess.check_output(
            ["findmnt", "-n", "-o", "TARGET", "-S", src],
            text=True, stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return []
    return [ln.strip() for ln in out.splitlines() if ln.strip()]

def path_under(a: str, b: str) -> bool:
    if not a or not b:
        return False
    a = a.rstrip("/")
    b = b.rstrip("/")
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")

def snap_count(repo: str, mountpoint: str, uuid: str):
    candidates = []
    if repo:
        candidates.append(repo)
    if mountpoint:
        mp = mountpoint.rstrip("/")
        candidates.append(mp + "/repo")
        candidates.append(mp + "/omaclone/repo")
    for t in live_targets(uuid):
        t = t.rstrip("/")
        candidates.append(t + "/omaclone/repo")
    seen = set()
    for c in candidates:
        if not c or c in seen:
            continue
        seen.add(c)
        snap = Path(c) / "snapshots"
        if not snap.is_dir():
            continue
        n = 0
        try:
            for p in snap.iterdir():
                if p.name.startswith(".") or not p.is_file():
                    continue
                n += 1
        except OSError:
            continue
        return n
    return None

data = load_toml(config)
forgotten = [t.strip() for t in (data.get("locations", {}).get("forgotten") or "").split("|") if t.strip()]
active = data.get("locations", {}).get("active", "")
ids_raw = data.get("locations", {}).get("ids", "")
ids = [x.strip() for x in ids_raw.replace(",", " ").split() if x.strip()]
keep_uuid = {}
for loc_id in ids:
    loc = data.get(f"locations.{loc_id}", {})
    if not loc.get("backend"):
        continue
    uuid = loc.get("uuid", "")
    if not uuid:
        continue
    if uuid not in keep_uuid:
        keep_uuid[uuid] = loc_id
    if loc_id == active:
        keep_uuid[uuid] = loc_id
out = []
seen_ids = set()
seen_uuid = set()
seen_mp = set()
for loc_id in ids:
    if loc_id in seen_ids:
        continue
    seen_ids.add(loc_id)
    loc = data.get(f"locations.{loc_id}", {})
    if not loc.get("backend"):
        continue
    uuid = loc.get("uuid", "")
    if uuid and keep_uuid.get(uuid) != loc_id:
        continue
    rec = {
        "id": loc_id,
        "label": loc.get("label") or loc_id,
        "backend": loc.get("backend", ""),
        "schedule": loc.get("schedule") or "on",
        "connected": connected(loc),
        "active": loc_id == active,
        "source": "config",
        "repo": loc.get("repo", ""),
        "mountpoint": loc.get("mountpoint", ""),
        "uuid": loc.get("uuid", ""),
        "mode": loc.get("mode", ""),
        "preset": loc.get("preset", ""),
        "profile": loc.get("profile", ""),
    }
    if rec["connected"]:
        n = snap_count(rec["repo"], rec["mountpoint"], rec["uuid"])
        if n is not None:
            rec["snapshotCount"] = n
    out.append(rec)
    if rec["uuid"]:
        seen_uuid.add(rec["uuid"])
    if rec["mountpoint"]:
        seen_mp.add(rec["mountpoint"])
    for t in live_targets(rec["uuid"]):
        seen_mp.add(t)

discover = root / "scripts" / "discover_bootstrap.py"
if not os.environ.get("OMACLONE_SKIP_DISCOVER"):
    if discover.is_file():
        try:
            proc = subprocess.run(
                [sys.executable, str(discover)],
                capture_output=True,
                text=True,
                check=False,
                timeout=2,
            )
            for line in proc.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                uri = d.get("uri") or d.get("id") or ""
                disc_uuid = d.get("uuid", "")

                if disc_uuid and disc_uuid in seen_uuid:
                    continue

                skip = False
                if forgotten:
                    for tok in forgotten:
                        if disc_uuid and tok == disc_uuid:
                            skip = True
                            break
                        if uri and (tok == uri or path_under(uri, tok)):
                            skip = True
                            break
                if skip:
                    continue

                if uri in seen_mp:
                    skip = True
                if not skip:
                    for mp in seen_mp:
                        if path_under(uri, mp):
                            skip = True
                            break
                if not skip:
                    for rec in out:
                        if rec.get("uuid") and disc_uuid and rec["uuid"] == disc_uuid:
                            skip = True
                            break
                if not skip:
                    try:
                        real_uri = os.path.realpath(uri)
                    except (OSError, ValueError):
                        real_uri = uri
                    for mp in seen_mp:
                        try:
                            if os.path.samefile(real_uri, mp):
                                skip = True
                                break
                        except OSError:
                            continue
                        if path_under(real_uri, mp):
                            skip = True
                            break

                if skip:
                    continue
                disc_rec = {
                    "id": f"discovered:{uri}",
                    "label": d.get("label") or f"Discovered {uri}",
                    "backend": d.get("backend") or "disk",
                    "schedule": "off",
                    "connected": True,
                    "active": False,
                    "source": "discovered",
                    "repo": "",
                    "mountpoint": uri,
                    "uuid": disc_uuid,
                    "config": d.get("config") or "",
                }
                n = snap_count("", uri, disc_uuid)
                if n is not None:
                    disc_rec["snapshotCount"] = n
                out.append(disc_rec)
                if disc_uuid:
                    seen_uuid.add(disc_uuid)
                seen_mp.add(uri)
        except (OSError, subprocess.TimeoutExpired):
            pass

json.dump(out, sys.stdout, separators=(",", ":"))
print()
PY
}
