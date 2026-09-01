#!/usr/bin/env bash
# Sourced by scripts/omaclone — not a standalone entrypoint.
set +o history 2>/dev/null || true
unset HISTFILE
set +x +v
set -euo pipefail

_maybe_generate_restic_password() {
  local backend
  backend=$(config_get secrets.backend)
  [[ "$backend" == keyring ]] || return 0
  if nas_backup_backend_run secrets keyring get >/dev/null 2>&1; then
    return 0
  fi
  if ! tui_confirm "Generate a new restic password and store it in the keyring?"; then
    return 0
  fi
  local pw
  pw=$(generate_restic_password)
  printf '%s' "$pw" | nas_backup_backend_run secrets keyring put
  tui_note "Password generated and stored. It is shown once — save it in your password manager."
  printf '%s\n' "$pw" >/dev/tty
  unset pw
  if tui_confirm "I have saved this password somewhere I can reach after a reinstall"; then
    return 0
  fi
  die "store the restic password before continuing; it cannot be recovered from the repo"
}

_setup_pick_destination() {
  local where transport
  where=$(printf '%s\n' \
    "NAS (TrueNAS, Synology, Unraid, …)" \
    "Extra disk (USB, 2nd drive, cold storage)" \
    "Cloud (S3-compatible: R2, AWS, Wasabi, B2, MinIO)" \
    "A path that is already mounted" \
    | gum choose --header="Where should this clone live?")
  case "$where" in
    NAS*)
      config_set destination.profile nas
      local vendor
      vendor=$(printf '%s\n' \
        "TrueNAS (NFS recommended)" \
        "Synology (SMB or SFTP recommended)" \
        "Other" \
        | gum choose --header="What kind of NAS?")
      case "$vendor" in
        TrueNAS*)
          config_set destination.vendor truenas
          tui_note "A dedicated NFS dataset is typical. Prefer NFSv4."
          ;;
        Synology*)
          config_set destination.vendor synology
          tui_note "SMB or SFTP is usually easier than NFS uid mapping on Synology."
          ;;
        *)
          config_set destination.vendor other
          ;;
      esac
      transport=$(nas_backup_backend_choose_all transport "How should this machine reach the NAS?" nfs cifs sftp)
      nas_backup_backend_ensure transport "$transport" || die "could not install $transport CLI; fix and re-run: omaclone setup"
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

_setup_init_repo() {
  if ! have restic; then
    tui_note "Installing restic…"
    sudo pacman -S --needed --noconfirm restic jq
  fi
  need_cmd restic jq
  _setup_ensure_transport || return $?
  local repo parent
  repo=$(restic_repo)
  parent=$(dirname "$repo")
  case "$repo" in
    s3:*|sftp:*) parent="" ;;
  esac
  if [[ -n "$parent" && ! -d "$parent" ]]; then
    mkdir -p "$parent" || die "cannot create $parent"
  fi
  if [[ -n "$parent" ]] && ! dir_is_writable "$parent"; then
    explain_nfs_uid_mismatch "$parent"
    die "backup location is not writable as uid $(id -u)"
  fi

  while true; do
    password_load || return 1
    transport_prepare_env
    local errfile rc looks_wrong=0
    errfile=$(mktemp -p "$(_password_tmpdir)" omaclone.err.XXXXXX)
    set +e
    restic_exec cat config >/dev/null 2>"$errfile"
    rc=$?
    set -e
    if grep -qi 'wrong password\|no key found' "$errfile" 2>/dev/null; then
      looks_wrong=1
    fi
    rm -f "$errfile"
    password_cleanup

    if (( rc == 0 )); then
      tui_note "Repository already exists at $repo"
      mark_repo_initialized
      return 0
    fi

    case "$repo" in
      s3:*|sftp:*) ;;
      *) [[ -f "$repo/config" ]] && looks_wrong=1 ;;
    esac

    if (( looks_wrong )); then
      tui_error "The password did not open the repository at $repo."
      local choice
      choice=$(printf '%s\n' \
        "Try a different password" \
        "Continue later" \
        | gum choose --header="Password mismatch") || return 1
      case "$choice" in
        Try*)
          nas_backup_backend_run secrets "$(config_get secrets.backend)" setup
          continue
          ;;
        Continue*)
          tui_note "Run: omaclone setup"
          return 2
          ;;
      esac
    else
      if tui_confirm "Initialize a new restic repository at $repo?"; then
        password_load || return 1
        transport_prepare_env
        restic_exec init
        password_cleanup
        mark_repo_initialized
        return 0
      else
        tui_note "Repository not initialized. Run: omaclone setup"
        return 2
      fi
    fi
  done
}

_setup_register_location() {
  local suggested id label schedule backend mode uuid existing
  backend=$(config_get transport.backend)
  mode=$(config_get transport.mode)
  uuid=$(config_get transport.uuid)
  existing=""
  if [[ -n "$uuid" ]]; then
    existing=$(location_find_id_by_uuid "$uuid" || true)
  fi
  if [[ -n "$existing" ]]; then
    suggested="$existing"
  else
    suggested=$(location_slug "$(location_default_label "$backend" "$(config_get destination.profile)" "$mode")")
  fi
  if command -v gum >/dev/null 2>&1; then
    label=$(gum input --placeholder "Name for this location" --value "$(location_get "$existing" label "$(location_default_label "$backend" "$(config_get destination.profile)" "$mode")")" </dev/tty)
    if [[ -n "$existing" ]]; then
      id="$existing"
    else
      id=$(gum input --placeholder "Short id" --value "$suggested" </dev/tty)
    fi
  else
    label=$(location_default_label "$backend" "$(config_get destination.profile)" "$mode")
    id="$suggested"
  fi
  if [[ -n "$existing" ]]; then
    id="$existing"
  else
    id=$(location_slug "$id")
  fi
  schedule=$(location_default_schedule "$backend" "$mode")
  if [[ "$schedule" == off ]]; then
    :
  elif tui_confirm "Run automatic daily clones to this location?"; then
    schedule=on
  else
    schedule=off
  fi
  location_save_current "$id" "$label" "$schedule"
  config_set locations.active "$id"
  LOCATION_LAST_ID="$id"
}

_setup_accept_defer() {
  local rc="${1:-1}"
  (( rc == 0 || rc == 2 )) && return 0
  return "$rc"
}

_setup_install_or_schedule() {
  local loc sched
  loc=$(location_active_id)
  sched=$(location_get "$loc" schedule on)
  if [[ "$sched" == on ]]; then
    # Daily clones need the user timer units, even if PATH already exists.
    cmd_install
    return 0
  fi
  if [[ -L "$HOME/.local/bin/omaclone" ]]; then
    location_schedule_apply
    return 0
  fi
  if tui_confirm "Install the PATH command, bar plugin, and timers?"; then
    cmd_install
  else
    location_schedule_apply
  fi
}

_setup_secrets() {
  local secrets
  secrets=$(nas_backup_backend_choose_all secrets "How should omaclone get the restic password?") || return 1
  nas_backup_backend_ensure secrets "$secrets" || die "could not install $secrets CLI; fix and re-run: omaclone setup"
  [[ "$secrets" == "keyring" ]] || config_set secrets.keyring_offer ""
  nas_backup_backend_run secrets "$secrets" setup
  _maybe_generate_restic_password
}

_setup_reenter_transport_secrets() {
  local backend keys key
  backend=$(config_get transport.backend)
  [[ -n "$backend" ]] || return 1
  keys=$(nas_backup_backend_run transport "$backend" credential-keys 2>/dev/null || true)
  [[ -n "${keys//[$'\n' ]/}" ]] || return 1
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    transport_secret_prompt_and_store "$key" "$key" || return 1
  done <<< "$keys"
}

_setup_ensure_transport() {
  local backend picked
  backend=$(config_get transport.backend)
  [[ -n "$backend" ]] || die "no transport configured; run: omaclone setup"
  while true; do
    if nas_backup_backend_run transport "$backend" ready; then
      return 0
    fi
    nas_backup_backend_run transport "$backend" mount 2>/dev/null || true
    if nas_backup_backend_run transport "$backend" ready; then
      return 0
    fi
    if ! is_tty || ! have gum; then
      die "transport '$backend' is not ready"
    fi
    picked=$(printf '%s\n' \
      "Retry connecting" \
      "Re-enter destination passwords / keys" \
      "Continue later" \
      | gum choose --header="Clone location is not ready") || return 1
    case "$picked" in
      Retry*) continue ;;
      Re-enter*)
        if ! _setup_reenter_transport_secrets; then
          tui_note "This destination has no stored keys to update (or entry was cancelled)."
        fi
        ;;
      Continue*)
        tui_note "Destination is saved. Run: omaclone setup"
        return 2
        ;;
    esac
  done
}

_setup_continue() {
  local secrets transport notify
  transport=$(config_get transport.backend)
  if [[ -n "$transport" ]]; then
    nas_backup_backend_ensure transport "$transport" || die "could not ensure $transport CLI; fix and re-run: omaclone setup"
  fi
  if [[ -n "$(config_get secrets.backend)" ]]; then
    secrets=$(config_get secrets.backend)
    nas_backup_backend_ensure secrets "$secrets" || die "could not ensure $secrets CLI; fix and re-run: omaclone setup"
  else
    _setup_secrets || return 1
  fi
  if [[ -n "$(config_get notify.backend)" ]]; then
    notify=$(config_get notify.backend)
    nas_backup_backend_ensure notify "$notify" || die "could not ensure $notify CLI; fix and re-run: omaclone setup"
  else
    local notify
    notify=$(nas_backup_backend_choose_all notify "Notifications")
    nas_backup_backend_ensure notify "$notify" || die "could not install $notify CLI; fix and re-run: omaclone setup"
    nas_backup_backend_run notify "$notify" setup 2>/dev/null || true
    config_set notify.backend "$notify"
  fi
  if [[ -z "$(config_get restore.profile)" ]]; then
    config_set restore.profile portable
  fi
  if [[ -z "$(config_get retention.preset)" ]]; then
    local keep
    keep=$(choose_retention_preset "How long should clones be kept?")
    config_set retention.preset "$keep"
    tui_note "Keeping: $(retention_label "$keep")"
  fi
  _setup_init_repo
  _setup_accept_defer $? || return
  if [[ -z "$(config_get locations.ids)" ]]; then
    _setup_register_location
  fi

  _setup_install_or_schedule

  local card
  card=$(write_recovery_card)
  tui_header "Recovery card"
  cat "$card"
  tui_note "Saved to $card — keep it with the restic password. It contains no secrets."
  nas_backup_backend_run transport "$(config_get transport.backend)" bootstrap-install 2>/dev/null || true

  local est
  est=$(clone_estimate_text 2>/dev/null || true)
  if [[ -n "$est" ]]; then
    tui_note "This identity is about $est on disk (Steam/ollama/caches excluded)."
  fi
  if tui_confirm "Run the first clone now?"; then
    cmd_backup
  fi
}

cmd_setup() {
  require_core_deps
  require_gum
  migrate_locations

  local sub="${1:-}"
  case "$sub" in
    secrets)
      tui_header "Omaclone setup — reconfigure password source"
      _setup_secrets || return
      password_load || return 0
      password_cleanup
      tui_note "Password source is ready."
      return
      ;;
    continue)
      tui_header "Omaclone setup — resume"
      _setup_continue; return
      ;;
  esac

  if [[ -n "$sub" ]]; then
    die "usage: omaclone setup [secrets|continue]"
  fi

  tui_header "Omaclone setup"
  tui_note "This writes ~/.config/omaclone/config.toml. It never stores the restic password."

  if [[ -n "$(config_get transport.backend)" && -z "$(config_get restic.repo)" ]]; then
    tui_note "Destination was not fully configured. Re-picking location…"; _setup_pick_destination; _setup_continue; return
  fi

  if setup_is_unfinished; then
    local choice
    choice=$(printf '%s\n' \
      "Continue setup" \
      "Change how omaclone gets the restic password" \
      "Replace this location's destination" \
      "Start over" \
      | gum choose --header="Omaclone setup is unfinished") || return 1
    case "$choice" in
      Continue*)
        local resume_msg="Continuing setup"
        if [[ -z "$(config_get secrets.backend)" ]]; then
          resume_msg="Configuring password source…"
        elif ! repo_initialized; then
          resume_msg="Initializing restic repository…"
        elif [[ -z "$(config_get locations.ids)" ]]; then
          resume_msg="Registering backup location…"
        fi
        tui_note "$resume_msg"; _setup_continue; return ;;
      Change*)
        _setup_secrets
        password_load || return 0
        password_cleanup
        tui_note "Password source updated. Continuing setup…"; _setup_continue; return
        ;;
      Replace*)
        _setup_pick_destination
        _setup_init_repo
        _setup_accept_defer $? || return
        if [[ -z "$(location_active_id)" ]]; then
          _setup_register_location
        else
          location_save_current "$(location_active_id)"
        fi
        location_schedule_apply
        return
        ;;
      Start*)
        tui_confirm "This resets setup state. The restic repository on disk is not deleted." || return 0
        setup_start_over
        LOCATION_LAST_ID=""
        tui_note "Setup cleared. Choose a destination."
        ;;
    esac
  elif [[ -n "$(config_get transport.backend)" ]]; then
    local next
    next=$(printf '%s\n' \
      "Add another clone location" \
      "Switch clone location" \
      "Replace this location's destination" \
      "Restore from an existing clone" \
      "Change how omaclone gets the restic password" \
      | gum choose --header="Omaclone is already configured")
    case "$next" in
      Add*) cmd_location add; return ;;
      Switch*) cmd_location switch; return ;;
      Replace*)
        _setup_pick_destination
        _setup_init_repo
        _setup_accept_defer $? || return
        if [[ -z "$(location_active_id)" ]]; then
          _setup_register_location
        else
          location_save_current "$(location_active_id)"
        fi
        location_schedule_apply
        return
        ;;
      Restore*) cmd_restore; return ;;
      Change*)
        _setup_secrets
        password_load || return 0
        password_cleanup
        return
        ;;
    esac
  fi

  local intent
  intent=$(printf '%s\n' "Create a clone" "Restore from an existing clone" \
    | gum choose --header="What do you want to do?")
  if [[ "$intent" == Restore* ]]; then
    cmd_restore
    return
  fi

  _setup_pick_destination
  _setup_continue
}
