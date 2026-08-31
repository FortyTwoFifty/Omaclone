if [[ -n "${OMACLONE_NFS_LIB_LOADED:-}" ]]; then
  return 0
fi
OMACLONE_NFS_LIB_LOADED=1

set +x +v

NFS_HOST=""
NFS_EXPORT=""

nfs_fstype() {
  if command -v mount.nfs4 >/dev/null 2>&1; then
    printf '%s\n' nfs4
  else
    printf '%s\n' nfs
  fi
}

nfs_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s\n' "$s"
}

nfs_parse_uri() {
  local uri
  uri=$(nfs_trim "${1:-}")
  NFS_HOST=""
  NFS_EXPORT=""
  [[ -n "$uri" ]] || return 1

  if [[ "$uri" == \[*\]:/* ]]; then
    NFS_HOST="${uri%%]*}"
    NFS_HOST="${NFS_HOST#\[}"
    NFS_EXPORT="${uri#*]:}"
  elif [[ "$uri" == *:* ]]; then
    NFS_HOST="${uri%%:*}"
    NFS_EXPORT="${uri#*:}"
  else
    return 1
  fi

  NFS_EXPORT="${NFS_EXPORT%/}"
  [[ -n "$NFS_EXPORT" ]] || NFS_EXPORT="/"
  [[ -n "$NFS_HOST" && -n "$NFS_EXPORT" ]] || return 1
  return 0
}

nfs_validate_uri() {
  local uri
  uri=$(nfs_trim "${1:-}")
  if [[ -z "$uri" ]]; then
    printf '%s\n' "NFS URI is required. Use host:/export (example: 10.10.0.10:/mnt/pool/backups)." >&2
    return 1
  fi
  if [[ "$uri" == *$'\n'* || "$uri" == *$'\t'* ]]; then
    printf '%s\n' "NFS URI must be a single host:/export value." >&2
    return 1
  fi
  if [[ "$uri" == //* ]]; then
    printf '%s\n' "That looks like an SMB path (//server/share). NFS needs host:/export." >&2
    return 1
  fi
  if [[ "$uri" == *://* ]]; then
    printf '%s\n' "Use host:/export, not a URL. Example: 10.10.0.10:/mnt/pool/backups" >&2
    return 1
  fi
  if ! nfs_parse_uri "$uri"; then
    printf '%s\n' "NFS URI must be host:/export (example: 10.10.0.10:/mnt/pool/backups)." >&2
    return 1
  fi
  if [[ "$NFS_HOST" == */* || "$NFS_HOST" == *' '* ]]; then
    printf '%s\n' "NFS host is invalid in '$uri'." >&2
    return 1
  fi
  if [[ "$NFS_EXPORT" != /* ]]; then
    printf '%s\n' "NFS export path must be absolute (got '${NFS_EXPORT}')." >&2
    return 1
  fi
  return 0
}

nfs_validate_mountpoint() {
  local mp
  mp=$(nfs_trim "${1:-}")
  if [[ -z "$mp" ]]; then
    printf '%s\n' "Mountpoint is required (example: /mnt/omaclone)." >&2
    return 1
  fi
  mp="${mp%/}"
  [[ -n "$mp" ]] || mp="/"
  if [[ "$mp" != /* ]]; then
    printf '%s\n' "Mountpoint must be an absolute path (example: /mnt/omaclone)." >&2
    return 1
  fi
  if [[ "$mp" == //* || "$mp" == *' '* || "$mp" == *$'\n'* ]]; then
    printf '%s\n' "Mountpoint must be a single absolute path without spaces." >&2
    return 1
  fi
  case "$mp" in
    /|/mnt|/home|/usr|/etc|/boot|/var|/root|/opt|/tmp|/dev|/proc|/sys|/run)
      printf '%s\n' "Refusing to mount over $mp — pick a dedicated directory (example: /mnt/omaclone)." >&2
      return 1
      ;;
  esac
  return 0
}

nfs_validate_repo() {
  local repo mountpoint
  repo=$(nfs_trim "${1:-}")
  mountpoint=$(nfs_trim "${2:-}")
  mountpoint="${mountpoint%/}"
  if [[ -z "$repo" ]]; then
    printf '%s\n' "Restic repo path is required." >&2
    return 1
  fi
  if [[ "$repo" != /* ]]; then
    printf '%s\n' "Restic repo path must be absolute." >&2
    return 1
  fi
  if [[ -z "$mountpoint" ]]; then
    return 0
  fi
  case "$repo" in
    "$mountpoint"|"$mountpoint"/*) ;;
    *)
      printf '%s\n' "Restic repo must live on the NFS mount ($mountpoint), not $repo." >&2
      return 1
      ;;
  esac
  return 0
}

nfs_host_resolves() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 0
  fi
  if [[ "$host" == *:* ]]; then
    return 0
  fi
  getent ahosts "$host" >/dev/null 2>&1 || getent hosts "$host" >/dev/null 2>&1
}

nfs_unit_names() {
  local mountpoint="$1"
  NFS_MOUNT_UNIT=$(systemd-escape -p --suffix=mount "$mountpoint")
  NFS_AUTO_UNIT=${NFS_MOUNT_UNIT%.mount}.automount
}

nfs_findmnt_nfs_source() {
  findmnt -n -t nfs,nfs4 -o SOURCE --target "$1" 2>/dev/null | awk 'NR==1 { print; exit }'
}

nfs_findmnt_first_source() {
  findmnt -n -o SOURCE --target "$1" 2>/dev/null | awk 'NR==1 { print; exit }'
}

nfs_findmnt_covers() {
  findmnt -n --target "$1" >/dev/null 2>&1
}

nfs_unit_what() {
  nfs_unit_names "$1"
  systemctl show -p What --value "$NFS_MOUNT_UNIT" 2>/dev/null || true
}

nfs_source_matches_uri() {
  local src="$1" uri="$2"
  local want_host want_export
  nfs_parse_uri "$uri" || return 1
  want_host="$NFS_HOST"
  want_export="$NFS_EXPORT"
  if nfs_parse_uri "$src"; then
    [[ "$NFS_HOST" == "$want_host" && "$NFS_EXPORT" == "$want_export" ]]
    return
  fi
  [[ "$src" == *"$want_export"* ]]
}

nfs_already_mounted() {
  local uri="$1" mountpoint="$2"
  local src what
  nfs_parse_uri "$uri" || return 1
  src=$(nfs_findmnt_nfs_source "$mountpoint")
  if [[ -n "$src" ]] && nfs_source_matches_uri "$src" "$uri"; then
    return 0
  fi
  nfs_findmnt_covers "$mountpoint" || return 1
  what=$(nfs_unit_what "$mountpoint")
  [[ -n "$what" ]] && nfs_source_matches_uri "$what" "$uri"
}

nfs_mountpoint_busy() {
  local uri="$1" mountpoint="$2"
  nfs_findmnt_covers "$mountpoint" || return 1
  nfs_already_mounted "$uri" "$mountpoint" && return 1
  return 0
}

nfs_mountpoint_source_label() {
  local mountpoint="$1"
  local src
  src=$(nfs_findmnt_nfs_source "$mountpoint")
  [[ -n "$src" ]] || src=$(nfs_findmnt_first_source "$mountpoint")
  printf '%s\n' "${src:-another filesystem}"
}

nfs_explain_unavailable() {
  local uri="$1"
  nfs_parse_uri "$uri" || true
  cat >&2 <<EOF
omaclone: NFS share is not available: $uri

No systemd mount units were installed.

Check:
  • the URI is host:/export (example: 10.10.0.10:/mnt/pool/backups)
  • this machine can reach the NAS
  • the export exists and this client is allowed
EOF
  if command -v showmount >/dev/null 2>&1 && [[ -n "${NFS_HOST:-}" ]]; then
    local exports
    exports=$(timeout 5 showmount -e "$NFS_HOST" 2>/dev/null || true)
    if [[ -n "$exports" ]]; then
      printf '\nExports advertised by %s:\n%s\n' "$NFS_HOST" "$exports" >&2
    fi
  fi
}

nfs_probe_mount() {
  local uri="$1"
  local tmp fstype rc=0
  nfs_validate_uri "$uri" || return 1
  tmp=$(mktemp -d /tmp/omaclone-nfs-probe.XXXXXX)
  fstype=$(nfs_fstype)
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 sudo mount -t "$fstype" -o "ro,soft,timeo=30,retrans=2,retry=0,fg,_netdev" "$uri" "$tmp"
    rc=$?
  else
    sudo mount -t "$fstype" -o "ro,soft,timeo=30,retrans=2,retry=0,fg,_netdev" "$uri" "$tmp"
    rc=$?
  fi
  if (( rc == 0 )); then
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 ls "$tmp" >/dev/null 2>&1
    else
      ls "$tmp" >/dev/null 2>&1
    fi
    rc=$?
  fi
  sudo umount -l "$tmp" 2>/dev/null || true
  rmdir "$tmp" 2>/dev/null || true
  set -e
  if (( rc != 0 )); then
    nfs_explain_unavailable "$uri"
    return 1
  fi
  printf '%s\n' "NFS share is available: $uri" >&2
  return 0
}

nfs_check_available() {
  local uri="$1"
  nfs_validate_uri "$uri" || return 1
  if ! nfs_host_resolves "$NFS_HOST"; then
    printf '%s\n' "Host '$NFS_HOST' did not resolve. Use a hostname or IP this machine can reach." >&2
    printf '%s\n' "No systemd mount units were installed." >&2
    return 1
  fi
  printf '%s\n' "Probing $uri (timed test mount; no systemd units yet)…" >&2
  nfs_probe_mount "$uri"
}

nfs_rollback_units() {
  local mountpoint="$1"
  local unit_dir="${2:-/etc/systemd/system}"
  local unit_name auto_name
  nfs_unit_names "$mountpoint"
  unit_name="$NFS_MOUNT_UNIT"
  auto_name="$NFS_AUTO_UNIT"
  sudo systemctl disable --now "$auto_name" >/dev/null 2>&1 || true
  sudo systemctl stop "$unit_name" >/dev/null 2>&1 || true
  sudo umount -l "$mountpoint" >/dev/null 2>&1 || true
  sudo rm -f "$unit_dir/$unit_name" "$unit_dir/$auto_name"
  sudo systemctl daemon-reload >/dev/null 2>&1 || true
  printf '%s\n' "removed $auto_name and $unit_name (share was not available)" >&2
}

nfs_install_automount() {
  local uri="${1:-}"
  local mountpoint="${2:-/mnt/omaclone}"
  local unit_dir=/etc/systemd/system
  local tmp unit_name auto_name

  if [[ -z "$uri" ]]; then
    printf '%s\n' "usage: install-nfs-mount.sh host:/export [mountpoint]" >&2
    return 2
  fi
  nfs_validate_uri "$uri" || return 2
  nfs_validate_mountpoint "$mountpoint" || return 2
  mountpoint="${mountpoint%/}"

  if nfs_mountpoint_busy "$uri" "$mountpoint"; then
    printf '%s\n' "$mountpoint is already mounted from $(nfs_mountpoint_source_label "$mountpoint"). Pick a different mountpoint or unmount it first." >&2
    return 1
  fi

  if [[ "${OMACLONE_NFS_ALREADY_PROBED:-}" != 1 ]]; then
    if nfs_already_mounted "$uri" "$mountpoint"; then
      printf '%s\n' "already mounted: $uri -> $mountpoint" >&2
    else
      nfs_check_available "$uri" || return 1
    fi
  fi

  nfs_unit_names "$mountpoint"
  unit_name="$NFS_MOUNT_UNIT"
  auto_name="$NFS_AUTO_UNIT"

  tmp=$(mktemp -d)
  cat >"$tmp/$unit_name" <<EOF
[Unit]
Description=Omaclone NFS share
After=network-online.target
Wants=network-online.target

[Mount]
What=$uri
Where=$mountpoint
Type=$(nfs_fstype)
Options=rw,hard,noatime,nosuid,nodev,noexec,proto=tcp,_netdev
EOF

  cat >"$tmp/$auto_name" <<EOF
[Unit]
Description=Automount Omaclone NFS share

[Automount]
Where=$mountpoint
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
EOF

  sudo mkdir -p "$mountpoint"
  sudo cp "$tmp/$unit_name" "$tmp/$auto_name" "$unit_dir/"
  rm -rf "$tmp"
  sudo systemctl daemon-reload

  if ! sudo systemctl enable --now "$auto_name"; then
    printf '%s\n' "failed to enable $auto_name" >&2
    nfs_rollback_units "$mountpoint" "$unit_dir"
    return 1
  fi

  if ! sudo systemctl start "$unit_name"; then
    printf '%s\n' "automount enabled but $unit_name did not start" >&2
    nfs_rollback_units "$mountpoint" "$unit_dir"
    return 1
  fi

  if ! findmnt -n "$mountpoint" >/dev/null 2>&1; then
    printf '%s\n' "automount enabled but $mountpoint is not mounted" >&2
    nfs_rollback_units "$mountpoint" "$unit_dir"
    return 1
  fi

  printf '%s\n' "enabled $auto_name ($uri -> $mountpoint)" >&2
}
