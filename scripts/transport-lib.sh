set +x +v
set -euo pipefail

cfg() {
  python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get "$1" "${2:-}"
}

cfg_set() {
  python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set "$1" "$2"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

sudo_noninteractive() {
  if [[ -t 0 && -t 1 ]]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

# Interactive disk/NFS setup: ask on /dev/tty after gum has taken stdin.
# Cron and tests (no tty) stay passwordless sudo -n.
sudo_tty() {
  if [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]] && { [[ -t 0 || -t 1 || -t 2 ]]; }; then
    sudo "$@" <>/dev/tty 2>/dev/tty
  elif [[ -t 0 && -t 1 ]]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

mount_wake() {
  local mp="${1:-}"
  [[ -n "$mp" ]] || return 0
  if have_cmd timeout; then
    timeout 8 stat "$mp" >/dev/null 2>&1 || true
  else
    stat "$mp" >/dev/null 2>&1 || true
  fi
}

# Exact mountpoint, skipping autofs rows so idle automount is not "ready".
mount_fstype_live() {
  local mp="${1:-}"
  [[ -n "$mp" ]] || return 1
  findmnt -n -o FSTYPE "$mp" 2>/dev/null | awk '$1 != "" && $1 != "autofs" { print; exit }'
}

mount_is_type() {
  local mp="${1:-}" types="${2:-}"
  [[ -n "$mp" && -n "$types" ]] || return 1
  findmnt -n -t "$types" "$mp" >/dev/null 2>&1
}

gum_input() {
  local placeholder="$1"
  local value="${2:-}"
  if have_cmd gum; then
    if [[ -n "$value" ]]; then
      gum input --placeholder "$placeholder" --value "$value" </dev/tty
    else
      gum input --placeholder "$placeholder" </dev/tty
    fi
  else
    printf '%s\n' "$value"
  fi
}

gum_password() {
  local placeholder="$1"
  if have_cmd gum; then
    gum input --password --placeholder "$placeholder" </dev/tty
  else
    printf '%s\n' "gum is required to enter a password" >&2
    return 1
  fi
}

prompt_until() {
  local placeholder="$1"
  local value="${2:-}"
  local validator="$3"
  shift 3 || true
  local extra=("$@")
  local next
  while true; do
    next=$(gum_input "$placeholder" "$value") || return 1
    if "$validator" "$next" "${extra[@]}"; then
      printf '%s\n' "$next"
      return 0
    fi
    if ! have_cmd gum; then
      return 1
    fi
    value="$next"
  done
}

dispatch_transport() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    id) id ;;
    describe) describe ;;
    available) available ;;
    setup) setup ;;
    install) install ;;
    mount) mount ;;
    unmount) unmount ;;
    ready) ready ;;
    bootstrap-install) bootstrap-install ;;
    capabilities) capabilities ;;
    credential-keys) credential_keys ;;
    discover) discover ;;
    pre-restic) pre_restic ;;
    post-restic) post_restic ;;
    *) printf 'unknown verb: %s\n' "$cmd" >&2; exit 2 ;;
  esac
}

install() { return 0; }

capabilities() { printf '%s\n' "mount"; }
credential_keys() { return 0; }
discover() { return 0; }
pre_restic() { return 0; }
post_restic() { return 0; }

cifs_validate_unc() {
  local uri="${1:-}"
  uri="${uri#"${uri%%[![:space:]]*}"}"
  uri="${uri%"${uri##*[![:space:]]}"}"
  if [[ -z "$uri" ]]; then
    printf '%s\n' "SMB path is required (//server/share)." >&2
    return 1
  fi
  if [[ "$uri" == *$'\n'* || "$uri" == *$'\t'* || "$uri" == *' '* ]]; then
    printf '%s\n' "SMB path must be a single //server/share value." >&2
    return 1
  fi
  if [[ "$uri" == *','* ]]; then
    printf '%s\n' "SMB path must not contain commas (they become extra mount options)." >&2
    return 1
  fi
  if [[ "$uri" != //*/* ]]; then
    printf '%s\n' "SMB path must look like //server/share." >&2
    return 1
  fi
  if [[ "$uri" == *..* ]]; then
    printf '%s\n' "SMB path must not contain .." >&2
    return 1
  fi
  return 0
}
