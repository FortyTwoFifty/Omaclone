#!/usr/bin/env bash
# Sourced library — not a standalone entrypoint.
set +x +v
set -euo pipefail

cfg() {
  python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get "$1" "${2:-}"
}

cfg_set() {
  python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set "$1" "$2"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Resolve . and .. without requiring the path to exist.
omaclone_abspath() {
  python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1"
}

# Shared mountpoint check for NFS/CIFS/disk systemd units.
omaclone_validate_mountpoint() {
  local mp="${1:-}" resolved
  mp="${mp#"${mp%%[![:space:]]*}"}"
  mp="${mp%"${mp##*[![:space:]]}"}"
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
  if [[ "$mp" == //* || "$mp" == *' '* || "$mp" == *$'\n'* || "$mp" == *$'\t'* ]]; then
    printf '%s\n' "Mountpoint must be a single absolute path without spaces." >&2
    return 1
  fi
  if [[ "$mp" == *..* ]]; then
    printf '%s\n' "Mountpoint must not contain .." >&2
    return 1
  fi
  resolved=$(omaclone_abspath "$mp")
  case "$resolved" in
    /|/mnt|/home|/usr|/etc|/boot|/var|/root|/opt|/tmp|/dev|/proc|/sys|/run)
      printf '%s\n' "Refusing to mount over $resolved — pick a dedicated directory (example: /mnt/omaclone)." >&2
      return 1
      ;;
    /etc|/*/etc|/boot|/*/boot|/usr|/*/usr|/bin|/*/bin|/sbin|/*/sbin|/lib|/*/lib|/lib64|/*/lib64|/root|/*/root|/proc|/*/proc|/sys|/*/sys|/dev|/*/dev)
      printf '%s\n' "Refusing to mount over $resolved." >&2
      return 1
      ;;
    /var/tmp|/dev/shm)
      printf '%s\n' "Refusing to mount over $resolved." >&2
      return 1
      ;;
  esac
  if [[ -n "${HOME:-}" ]]; then
    case "$resolved" in
      "$HOME"|"$HOME"/*)
        printf '%s\n' "Refusing to mount over \$HOME ($resolved)." >&2
        return 1
        ;;
    esac
  fi
  printf '%s\n' "$resolved"
}

mount_is_exact() {
  local mp="${1:-}"
  [[ -n "$mp" ]] || return 1
  findmnt -n -M "$mp" >/dev/null 2>&1
}

omaclone_disk_uuid_ok() {
  local uuid="${1:-}"
  [[ "$uuid" =~ ^[0-9a-fA-F-]{8,36}$ ]] || return 1
  [[ "$uuid" != *..* && "$uuid" != */* ]] || return 1
  return 0
}

sudo_noninteractive() {
  if [[ -t 0 && -t 1 ]]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

# Interactive disk/NFS setup: ask on /dev/tty after gum has taken stdin.
# Cron and tests (no tty) stay passwordless sudo -n.
if ! declare -F sudo_tty >/dev/null 2>&1; then
  sudo_tty() {
    if [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]] && { [[ -t 0 || -t 1 || -t 2 ]]; }; then
      sudo "$@" <>/dev/tty 2>/dev/tty
    elif [[ -t 0 && -t 1 ]]; then
      sudo "$@"
    else
      sudo -n "$@"
    fi
  }
fi

# Fixed root-owned helper. Inherited payload overrides are ignored.
if ! declare -F omaclone_privileged >/dev/null 2>&1; then
  OMACLONE_PRIVILEGED_DEST="${OMACLONE_PRIVILEGED_DEST:-/usr/lib/omaclone/privileged.py}"
  OMACLONE_PRIVILEGED_SHA256="8481bfdd177c1fe2b476b7249c4c636e66dcb390801c1d6cf4b5e0cdcf3a8ae0"

  omaclone_privileged_clear_overrides() {
    unset _OMACLONE_PRIVILEGED_B64 _OMACLONE_PRIVILEGED_SRC OMACLONE_PRIVILEGED_B64
  }

  sudo_keep_stdin() {
    if [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]] && { [[ -t 0 || -t 1 || -t 2 ]]; }; then
      sudo "$@"
    elif [[ -t 0 && -t 1 ]]; then
      sudo "$@"
    else
      sudo -n "$@"
    fi
  }

  omaclone_privileged_src() {
    if [[ -n "${NAS_BACKUP_ROOT:-}" && -f "$NAS_BACKUP_ROOT/scripts/privileged.py" ]]; then
      printf '%s\n' "$NAS_BACKUP_ROOT/scripts/privileged.py"
    else
      printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/privileged.py"
    fi
  }

  omaclone_privileged_ensure() {
    omaclone_privileged_clear_overrides
    local src dest want
    dest="${OMACLONE_PRIVILEGED_DEST:-/usr/lib/omaclone/privileged.py}"
    src=$(omaclone_privileged_src)
    want="$OMACLONE_PRIVILEGED_SHA256"
    [[ -f "$src" ]] || { echo "omaclone: missing privileged helper" >&2; return 1; }
    if [[ "${OMACLONE_PRIVILEGED_TEST:-}" == 1 ]]; then
      return 0
    fi
    if [[ -f "$dest" ]]; then
      if sudo_tty /usr/bin/python3 "$dest" self-check --expect-sha256 "$want" >/dev/null 2>&1; then
        return 0
      fi
    fi
    printf '%s\n' "sudo — installing the Omaclone privileged helper to $dest" >&2
    python3 "$src" emit-if-digest --expect-sha256 "$want" | sudo_keep_stdin /bin/sh -c '
      set -euo pipefail
      dest="$1"
      want="$2"
      dir=$(dirname "$dest")
      mkdir -p -m 0755 "$dir"
      chown root:root "$dir"
      chmod 0755 "$dir"
      tmp="$dest.omaclone-new"
      rm -f "$tmp"
      cat >"$tmp"
      chown root:root "$tmp"
      chmod 0555 "$tmp"
      got=$(sha256sum -- "$tmp" | awk "{print \$1}")
      if [ "$got" != "$want" ]; then
        rm -f "$tmp"
        echo "omaclone: helper digest mismatch after install" >&2
        exit 1
      fi
      mv -f "$tmp" "$dest"
    ' _ "$dest" "$want"
  }

  omaclone_privileged() {
    omaclone_privileged_clear_overrides
    omaclone_privileged_ensure || return 1
    if [[ "${OMACLONE_PRIVILEGED_TEST:-}" == 1 ]]; then
      python3 "$(omaclone_privileged_src)" "$@"
      return
    fi
    sudo_tty /usr/bin/python3 "${OMACLONE_PRIVILEGED_DEST:-/usr/lib/omaclone/privileged.py}" "$@"
  }

  omaclone_privileged_load() { omaclone_privileged_ensure; }
fi

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
  findmnt -n -M "$mp" -o FSTYPE 2>/dev/null | awk '$1 != "" && $1 != "autofs" { print; exit }'
}

mount_is_type() {
  local mp="${1:-}" types="${2:-}"
  [[ -n "$mp" && -n "$types" ]] || return 1
  findmnt -n -M "$mp" -t "$types" >/dev/null 2>&1
}

gum_input() {
  local placeholder="$1"
  local value="${2:-}"
  local header="${3:-${GUM_INPUT_HEADER:-}}"
  if have_cmd gum; then
    local args=(input --placeholder "$placeholder")
    [[ -n "$value" ]] && args+=(--value "$value")
    [[ -n "$header" ]] && args+=(--header "$header")
    gum "${args[@]}" </dev/tty
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

if ! declare -F tui_brief >/dev/null 2>&1 && [[ -n "${NAS_BACKUP_ROOT:-}" && -f "$NAS_BACKUP_ROOT/scripts/tui.sh" ]]; then
  # shellcheck disable=SC1091
  source "$NAS_BACKUP_ROOT/scripts/tui.sh"
fi

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
    brief) brief ;;
    *) printf 'unknown verb: %s\n' "$cmd" >&2; exit 2 ;;
  esac
}

install() { return 0; }

capabilities() { printf '%s\n' "mount"; }
credential_keys() { return 0; }
discover() { return 0; }
pre_restic() { return 0; }
post_restic() { return 0; }

# Print the markdown briefing for this backend. Empty is fine (dummy / drop-ins).
brief() {
  local f="${NAS_BACKUP_ROOT:-}/briefs/${NAS_BACKUP_BACKEND:-}.txt"
  if [[ -n "${NAS_BACKUP_BACKEND:-}" && -f "$f" ]]; then
    cat "$f"
  fi
  return 0
}

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
