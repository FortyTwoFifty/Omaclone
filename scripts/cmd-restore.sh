#!/usr/bin/env bash
# Sourced by scripts/omaclone — not a standalone entrypoint.
set +o history 2>/dev/null || true
unset HISTFILE
set +x +v
set -euo pipefail

_restore_pick_snapshot() {
  local requested="${1:-}"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi
  local table
  table=$(restic_exec snapshots --json)
  if [[ "$(printf '%s' "$table" | jq 'length')" == 0 ]]; then
    die "no snapshots in $(restic_repo)"
  fi
  require_gum
  local lines picked
  lines=$(printf '%s' "$table" | jq -r '.[] | "\(.short_id)  \(.time)  \(.hostname)  \(.paths | join(","))"')
  picked=$(printf '%s\n' "$lines" | gum choose --header="Choose snapshot")
  printf '%s\n' "${picked%% *}"
}

_home_is_lived_in() {
  ! fresh_home
}

restore_choose_location() {
  require_gum
  local recs=() labels=() rec label picked i
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    recs+=("$rec")
    label=$(printf '%s' "$rec" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("label") or d.get("uri") or "")')
    labels+=("$label")
  done < <(python3 "$ROOT/scripts/discover_bootstrap.py")
  labels+=("NAS (NFS / SMB / SFTP)")
  labels+=("Extra disk or USB")
  labels+=("Cloud (S3-compatible)")
  labels+=("Local path")
  picked=$(printf '%s\n' "${labels[@]}" | gum choose --header="Where is the existing clone?")
  for i in "${!recs[@]}"; do
    if [[ "${labels[$i]}" == "$picked" ]]; then
      local cfgpath
      cfgpath=$(printf '%s' "${recs[$i]}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config") or "")')
      if [[ -n "$cfgpath" && -f "$cfgpath" ]]; then
        mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR"
        cp "$cfgpath" "$NAS_BACKUP_CONFIG"
        chmod 600 "$NAS_BACKUP_CONFIG"
        tui_note "Loaded config from $cfgpath"
        return 0
      fi
    fi
  done
  local transport
  case "$picked" in
    NAS*)
      config_set destination.profile nas
      transport=$(nas_backup_backend_choose transport "How do you reach the NAS?" nfs cifs sftp)
      ;;
    Extra*)
      config_set destination.profile disk
      transport=disk
      ;;
    Cloud*)
      config_set destination.profile cloud
      transport=s3
      ;;
    *)
      config_set destination.profile local
      transport=local
      ;;
  esac
  nas_backup_backend_run transport "$transport" setup
}

_restore_find_home() {
  local staging="$1"
  local src="$staging$HOME"
  if [[ -d "$src" ]]; then
    printf '%s\n' "$src"
    return 0
  fi
  src="$staging/home/$USER"
  if [[ -d "$src" ]]; then
    printf '%s\n' "$src"
    return 0
  fi
  local homes=()
  local d
  for d in "$staging/home"/*; do
    [[ -d "$d" ]] && homes+=("$d")
  done
  if ((${#homes[@]} == 1)); then
    tui_note "Snapshot home is ${homes[0]#"$staging"}; remapping onto $HOME"
    printf '%s\n' "${homes[0]}"
    return 0
  fi
  return 1
}

_restore_staging_dir() {
  local base="$NAS_BACKUP_STATE_DIR/restore-staging"
  mkdir -p "$base"
  chmod 700 "$base"
  mktemp -d "$base/omaclone-restore.XXXXXX"
}

_restore_rsync_excludes() {
  local line plugin_dir plugin_rel
  if [[ -f "$ROOT/config/excludes.txt" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      line="${line#/}"
      printf '%s\n' "$line"
    done <"$ROOT/config/excludes.txt" || true
  fi
  plugin_dir=$(omaclone_plugin_dest 2>/dev/null || true)
  plugin_rel="${plugin_dir#"$HOME"/}"
  if [[ -n "$plugin_dir" && "$plugin_rel" != "$plugin_dir" ]]; then
    printf '%s\n' "$plugin_rel"
  fi
  printf '%s\n' ".config/omarchy/plugins"
  return 0
}

_restore_extract_etc_tar() {
  local tarfile="$1" dest="$2"
  python3 - "$tarfile" "$dest" <<'PY'
import os, sys, tarfile
from pathlib import Path
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
dest.mkdir(parents=True, exist_ok=True)
with tarfile.open(src, "r:*") as tf:
    for m in tf.getmembers():
        name = m.name.replace("\\", "/")
        if name.startswith("/") or name.startswith("../") or "/../" in name or name.endswith("/.."):
            continue
        if not (name == "etc" or name.startswith("etc/")):
            continue
        tf.extract(m, dest, set_attrs=False)
PY
}

_restore_snapshot_line() {
  local id="$1"
  restic_exec snapshots "$id" --json 2>/dev/null | jq -r '.[0] | "\(.short_id)  \(.time)  \(.hostname)"' 2>/dev/null || printf '%s\n' "$id"
}

cmd_restore() {
  local same_machine=0 snapshot="" blank=0 replace=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --same-machine) same_machine=1 ;;
      --blank-omarchy)
        if [[ "${OMACLONE_TEST:-}" != 1 ]]; then
          die "--blank-omarchy is only for tests; type RESTORE in the TUI"
        fi
        blank=1
        ;;
      --delete|--replace) replace=1 ;;
      --snapshot)
        [[ $# -ge 2 ]] || die "omaclone restore --snapshot requires an ID"
        snapshot="$2"
        shift
        ;;
      *) die "unknown restore option: $1" ;;
    esac
    shift
  done

  if [[ -z "$(config_get transport.backend)" ]]; then
    restore_choose_location
  fi

  require_restore_deps
  require_gum
  need_cmd restic jq rsync
  if [[ -z "$(config_get secrets.backend)" ]]; then
    _setup_secrets || return 1
  fi
  omaclone_acquire_lock
  if declare -F _setup_ensure_transport >/dev/null; then
    _setup_ensure_transport || return 1
  else
    ensure_transport
  fi
  password_load || return 1
  transport_prepare_env

  local id
  id=$(_restore_pick_snapshot "$snapshot")
  [[ -n "$id" ]] || die "no snapshot selected"

  local snap_line
  snap_line=$(_restore_snapshot_line "$id")
  tui_note "Snapshot: $snap_line"
  tui_note "This overlays $HOME (ssh, gpg, browsers, and keyring files come back). Extra files already on this home stay unless you replace."

  if (( ! same_machine )) && is_tty && have gum; then
    if tui_confirm "Is this the same PC (you replaced the boot drive)?"; then
      same_machine=1
    fi
  fi

  if (( ! blank )); then
    local phrase
    phrase=$(gum input --header "Type RESTORE to overlay $HOME" --placeholder "RESTORE" </dev/tty) || die "aborted"
    [[ "$phrase" == RESTORE ]] || die "aborted"
  fi
  if (( replace )); then
    local phrase
    phrase=$(gum input --header "Type REPLACE to delete files on this home that are not in the clone" --placeholder "REPLACE" </dev/tty) || die "aborted"
    [[ "$phrase" == REPLACE ]] || die "aborted"
  fi

  local staging
  staging=$(_restore_staging_dir)
  chmod 700 "$staging"
  _restore_cleanup() {
    password_cleanup
    [[ -n "${staging:-}" ]] && rm -rf "$staging"
    finish_transport
  }
  trap '_restore_cleanup' EXIT
  trap '_restore_cleanup; _nas_backup_on_signal INT' INT
  trap '_restore_cleanup; _nas_backup_on_signal TERM' TERM

  log "restoring snapshot $id to $staging…"
  set +e
  restic_exec restore "$id" --target "$staging" --verify --json | restic_json_progress
  local rc=${PIPESTATUS[0]}
  set -e
  if (( rc != 0 )); then
    notify "Omaclone restore failed" "restic restore failed" critical
    die "restic restore failed"
  fi

  local src
  src=$(_restore_find_home "$staging") || die "restored tree did not contain a home directory"

  log "rsync into $HOME…"
  local rsync_excludes=()
  local rel
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    rsync_excludes+=(--exclude "$rel")
  done < <(home_foreign_mounts)
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    rsync_excludes+=(--exclude "$rel")
  done < <(_restore_rsync_excludes)
  local rsync_args=(-aH --info=progress2 --safe-links)
  if (( replace )); then
    rsync_args+=(--delete)
  fi
  rsync "${rsync_args[@]}" \
    "${rsync_excludes[@]}" \
    "$src"/ "$HOME"/

  local etc_tar
  if etc_tar=$(staging_file etc.tar); then
    local etc_dir="$staging/etc-extract"
    mkdir -p "$etc_dir"
    _restore_extract_etc_tar "$etc_tar" "$etc_dir"
    local allow="$ROOT/config/etc-restore.allow"
    if (( same_machine )) || [[ "$(config_get restore.profile)" == same-machine ]]; then
      log "same-machine: still refusing fstab/Limine/LUKS; applying allowlist only"
    fi
    tui_note "Restoring /etc with sudo — touch your FIDO key if prompted. This is not the Omaclone keyring."
    while IFS= read -r rel || [[ -n "$rel" ]]; do
      [[ -z "$rel" || "$rel" == \#* ]] && continue
      if ! etc_rel_ok "$rel"; then
        log "skip forbidden /etc path: $rel"
        continue
      fi
      local src="$etc_dir/etc/$rel"
      if [[ -L "$src" ]]; then
        log "skip symlink /etc path: $rel"
        continue
      fi
      if [[ -e "$src" ]] && find "$src" -type l -print -quit | grep -q .; then
        log "skip /etc path containing symlinks: $rel"
        continue
      fi
      if [[ -L "/etc/$rel" ]]; then
        log "skip existing dest symlink /etc/$rel"
        continue
      fi
      if [[ -e "$src" ]]; then
        if declare -F sudo_tty >/dev/null; then
          sudo_tty mkdir -p "/etc/$(dirname "$rel")"
          if [[ -d "$src" ]]; then
            sudo_tty mkdir -p "/etc/$rel"
            sudo_tty cp -a --no-dereference "$src"/. "/etc/$rel"/
          else
            sudo_tty cp -a --no-dereference "$src" "/etc/$rel"
          fi
        else
          sudo mkdir -p "/etc/$(dirname "$rel")"
          if [[ -d "$src" ]]; then
            sudo mkdir -p "/etc/$rel"
            sudo cp -a --no-dereference "$src"/. "/etc/$rel"/
          else
            sudo cp -a --no-dereference "$src" "/etc/$rel"
          fi
        fi
        log "restored /etc/$rel"
      fi
    done <"$allow"
  fi

  _restore_pacman_from_list() {
    local list="$1"
    local pkgs=() pkg
    while IFS= read -r pkg || [[ -n "$pkg" ]]; do
      pkg="${pkg%%#*}"
      pkg="${pkg//[$' \t']/}"
      [[ -n "$pkg" ]] || continue
      if [[ ! "$pkg" =~ ^[a-zA-Z0-9@._+-]+$ ]]; then
        log "skip invalid package name"
        continue
      fi
      pkgs+=("$pkg")
    done <"$list"
    ((${#pkgs[@]})) || return 0
    if declare -F sudo_tty >/dev/null; then
      tui_note "Installing packages with sudo — touch your FIDO key if prompted. This is not the Omaclone keyring."
      sudo_tty pacman -S --needed --noconfirm -- "${pkgs[@]}"
    else
      sudo pacman -S --needed --noconfirm -- "${pkgs[@]}"
    fi
  }

  local idlist
  if idlist=$(staging_file pkglist-identity.txt) && [[ -s "$idlist" ]]; then
    tui_note "Identity packages from the clone:"
    cat "$idlist" >&2 || true
    if tui_confirm "Install these packages with pacman now?"; then
      log "installing identity packages…"
      _restore_pacman_from_list "$idlist" || true
    else
      log "skipped identity package install"
    fi
  fi
  local aur
  if aur=$(staging_file pkglist-aur.txt) && [[ -s "$aur" ]] && have yay; then
    if tui_confirm "Install AUR identity packages with yay now?"; then
      log "installing AUR identity packages…"
      local pkg
      while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if [[ ! "$pkg" =~ ^[a-zA-Z0-9@._+-]+$ ]]; then
          log "skip invalid AUR package name"
          continue
        fi
        if match_hardware_pkg "$pkg"; then
          log "skip AUR hardware package: $pkg"
          continue
        fi
        yay -S --needed --noconfirm "$pkg" || true
      done <"$aur"
    else
      log "skipped AUR package install"
    fi
  fi
  local hwlist
  if hwlist=$(staging_file pkglist-hardware.txt) && [[ -s "$hwlist" ]]; then
    if (( same_machine )); then
      tui_note "Hardware packages from the previous boot drive:"
      cat "$hwlist" >&2 || true
      if tui_confirm "Install these hardware packages with pacman now? (same machine only)"; then
        _restore_pacman_from_list "$hwlist" || true
      else
        log "skipped hardware package install"
      fi
    else
      tui_note "Hardware packages were NOT installed (portable restore):"
      cat "$hwlist" >&2 || true
    fi
  fi

  loginctl enable-linger "$USER" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  local units_file unit
  if units_file=$(staging_file user-units-enabled.txt); then
    while IFS= read -r unit || [[ -n "$unit" ]]; do
      unit="${unit##*/}"
      unit="${unit%% *}"
      [[ "$unit" == *.service || "$unit" == *.timer ]] || continue
      [[ "$unit" == UNIT || "$unit" == UNITFILE ]] && continue
      if match_denied_unit "$unit"; then
        log "skip machine-local unit: $unit"
        continue
      fi
      log "enable user unit $unit"
      systemctl --user enable --now "$unit" 2>/dev/null || true
    done <"$units_file"
  fi

  password_cleanup
  finish_transport
  rm -rf "$staging"
  trap '_nas_backup_on_exit' EXIT
  trap '_nas_backup_on_signal INT' INT
  trap '_nas_backup_on_signal TERM' TERM
  trap '_nas_backup_on_signal HUP' HUP

  notify "Omaclone" "Identity restore finished."
  tui_header "Restore finished"
  cat <<EOF
Reboot, then:
  • Unlock your password manager / keyring
  • ssh, gpg, browsers, and desktop keyring files came back with \$HOME
  • Steam games and Proton saves are not in the clone; use Steam Cloud or re-download
  • ollama pull for local models
  • Re-enroll fingerprint if this machine has a reader
EOF
}
