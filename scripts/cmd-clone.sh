#!/usr/bin/env bash
# Sourced by scripts/omaclone — not a standalone entrypoint.
set +o history 2>/dev/null || true
unset HISTFILE
set +x +v
set -euo pipefail

cmd_init() {
  ensure_transport
  password_load || return 1
  transport_prepare_env
  restic_exec init
  password_cleanup
  mark_repo_initialized
  finish_transport
}

cmd_backup() {
  local cron=0 after_unlock=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cron) cron=1 ;;
      --after-unlock) cron=1; after_unlock=1 ;;
      *) die "unknown clone option: $1" ;;
    esac
    shift
  done
  need_cmd restic jq
  omaclone_acquire_lock
  if (( cron )); then
    ensure_transport --cron
  else
    ensure_transport
  fi

  if (( cron )) && [[ "$(config_get secrets.backend)" == prompt ]]; then
    write_last_result skip "Automatic clone skipped: prompt backend needs a terminal" password
    notify "Omaclone skipped" "The last clone did not run: the prompt password backend cannot run unattended." low
    log "skipping: prompt backend cannot run from a timer"
    exit 0
  fi

  if [[ "${OMACLONE_SKIP_PREP:-}" == 1 ]]; then
    log "prep skipped (OMACLONE_SKIP_PREP)"
  else
    log "running prep…"
    if ! "$ROOT/scripts/prep.sh"; then
      log "prep skipped; cloning \$HOME only"
    fi
  fi

  if ! password_load; then
    if (( cron )); then
      local secrets_backend
      secrets_backend=$(config_get secrets.backend)
      write_last_result skip "Password is not available (unlock keyring or sign in)" password
      if [[ "$secrets_backend" == keyring && "$after_unlock" -eq 0 ]]; then
        schedule_keyring_retry
        notify "Omaclone skipped" "The last clone did not run because the keyring was locked. It will run when you unlock it." low
      else
        notify "Omaclone skipped" "The last clone did not run because the password manager was locked." low
      fi
      log "skipping: password is not available"
      exit 0
    fi
    return 1
  fi
  transport_prepare_env
  local exclude="$ROOT/config/excludes.txt"
  local host extra_ex=() repo rel kit
  host=$(hostname)
  repo=$(restic_repo)
  if [[ "$repo" == "$HOME"/* ]]; then
    rel="${repo#"$HOME"/}"
    extra_ex+=(--exclude "$rel")
    kit=$(dirname "$rel")
    if [[ "$kit" != "." && "$kit" != "$rel" ]]; then
      extra_ex+=(--exclude "$kit")
    fi
  fi
  log "backing up $HOME → $repo"
  local errfile rc=0
  errfile=$(mktemp -p "$(_password_tmpdir)" omaclone.restic.XXXXXX)
  set +e
  restic_exec backup "$HOME" \
    --one-file-system \
    --exclude-file="$exclude" \
    "${extra_ex[@]}" \
    --tag identity \
    --tag omaclone \
    --tag nas-backup \
    --host "$host" \
    --json 2>"$errfile" | restic_json_progress
  rc=${PIPESTATUS[0]}
  set -e
  if (( rc == 0 )); then
    collect_repo_stats || true
  fi
  finish_transport
  password_cleanup

  if (( rc != 0 )); then
    local fail_msg
    fail_msg=$(restic_summarize_fail "$rc" "$errfile")
    rm -f "$errfile"
    write_last_result fail "$fail_msg"
    notify "Omaclone failed" "$fail_msg" critical
    die "$fail_msg"
  fi
  rm -f "$errfile"

  write_last_result ok "backup completed"
  if (( ! after_unlock )); then
    stop_keyring_retry
  fi
  mark_repo_initialized
  notify "Omaclone" "Identity clone finished."
  write_recovery_card >/dev/null
  if [[ "${OMACLONE_SKIP_BOOTSTRAP:-}" != 1 ]]; then
    nas_backup_backend_run transport "$(config_get transport.backend)" bootstrap-install 2>/dev/null || true
  fi
}

cmd_snapshots() {
  ensure_transport
  password_load || return 1
  transport_prepare_env
  restic_exec snapshots
  password_cleanup
  finish_transport
}

cmd_check() {
  ensure_transport
  password_load || return 1
  transport_prepare_env
  restic_exec check
  password_cleanup
  finish_transport
}

cmd_prune() {
  local cron=0
  [[ "${1:-}" == --cron ]] && cron=1
  omaclone_acquire_lock
  if (( cron )); then
    ensure_transport --cron
  else
    ensure_transport
  fi
  if (( cron )); then
    password_load || {
      write_last_result skip "Password is not available (unlock keyring or sign in)" password
      log "skipping prune: password is not available"
      exit 0
    }
  else
    password_load || return 1
  fi
  transport_prepare_env
  local args=()
  mapfile -t args < <(retention_forget_args)
  restic_exec forget --prune "${args[@]}" --tag identity
  collect_repo_stats || true
  password_cleanup
  finish_transport
}

cmd_forget() {
  local all=0 yes=0
  local ids=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=1 ;;
      --yes) yes=1 ;;
      -h|--help)
        printf '%s\n' "usage: omaclone forget [ID...] [--all] [--yes]"
        return 0
        ;;
      -*) die "unknown forget option: $1" ;;
      *) ids+=("$1") ;;
    esac
    shift
  done
  omaclone_acquire_lock
  ensure_transport
  password_load || return 1
  transport_prepare_env
  local table n
  table=$(restic_exec snapshots --json)
  n=$(printf '%s' "$table" | jq 'length')
  [[ "$n" != 0 && "$n" != "null" ]] || die "no clones in $(restic_repo)"
  if (( all )); then
    mapfile -t ids < <(printf '%s' "$table" | jq -r '.[].short_id')
  elif ((${#ids[@]} == 0)); then
    require_gum
    local lines picked
    lines=$(printf '%s' "$table" | jq -r '.[] | "\(.short_id)  \(.time)  \(.hostname)"')
    picked=$(printf '%s\n' "$lines" | gum choose --no-limit --header="Clones to remove") || die "aborted"
    ids=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && ids+=("${line%% *}")
    done <<< "$picked"
  fi
  ((${#ids[@]})) || die "no clones selected"
  if (( ! yes )); then
    require_gum
    tui_confirm "Remove ${#ids[@]} clone(s) from this location? This cannot be undone." || die "aborted"
  fi
  restic_exec forget --prune "${ids[@]}"
  collect_repo_stats || true
  password_cleanup
  finish_transport
}

cmd_estimate() {
  local text
  text=$(clone_estimate_text)
  printf '%s\n' "$text"
}

cmd_verify() {
  local subset="1/10"
  case "${1:-}" in
    --all) subset="1/1" ;;
    "" ) ;;
    *) die "usage: omaclone verify [--all]" ;;
  esac
  need_cmd restic
  omaclone_acquire_lock
  ensure_transport
  password_load || return 1
  transport_prepare_env
  log "restic check --read-data-subset=$subset"
  restic_exec check --read-data-subset="$subset"
  password_cleanup
  finish_transport
}

cmd_copy() {
  local dest_id="${1:-}"
  local src_id
  src_id=$(location_active_id)
  [[ -n "$src_id" ]] || die "no active location; run: omaclone setup"
  if [[ -z "$dest_id" ]]; then
    require_gum
    local json lines picked
    json=$(location_list_json)
    lines=$(printf '%s' "$json" | jq -r --arg src "$src_id" \
      '.[] | select(.source != "discovered" and .id != $src) | "\(.id) — \(.label)  [\(.backend), \(if .connected then "connected" else "offline" end)]"')
    [[ -n "$lines" ]] || die "no other saved locations; add one with: omaclone location add"
    picked=$(printf '%s\n' "$lines" | gum choose --header="Copy clones to which location?") || die "aborted"
    dest_id="${picked%% — *}"
  fi
  location_has "$dest_id" || die "unknown location: $dest_id"
  [[ "$dest_id" != "$src_id" ]] || die "already on location '$dest_id'"
  location_destination_edit_begin
  location_prepare_mount "$dest_id" || die "location '$dest_id' is not connected"
  local dest_backend dest_repo src_repo dest_mp dest_uuid dest_live
  dest_backend=$(location_get "$dest_id" backend)
  dest_repo=$(location_get "$dest_id" repo)
  dest_mp=$(location_get "$dest_id" mountpoint)
  dest_uuid=$(location_get "$dest_id" uuid)
  case "$dest_backend" in
    s3|sftp) die "copy currently supports mounted destinations (NAS share, disk, local path)" ;;
  esac
  if [[ -n "$dest_uuid" ]]; then
    dest_live=$(findmnt -n -o TARGET -S "/dev/disk/by-uuid/$dest_uuid" 2>/dev/null | head -n 1 || true)
    if [[ -n "$dest_live" ]]; then
      dest_repo=$(map_restic_repo_onto_mount "${dest_repo:-}" "$dest_mp" "$dest_live") || true
    fi
  elif [[ -n "$dest_mp" ]]; then
    dest_live=$(findmnt -n -M "$dest_mp" -o TARGET 2>/dev/null | head -n 1 || true)
    if [[ -n "$dest_live" && -n "$dest_repo" ]]; then
      dest_repo=$(map_restic_repo_onto_mount "$dest_repo" "$dest_mp" "$dest_live") || true
    fi
  fi
  [[ -n "$dest_repo" ]] || die "location '$dest_id' has no restic.repo"
  need_cmd restic
  omaclone_acquire_lock
  ensure_transport
  password_load || { location_destination_edit_end; return 1; }
  transport_prepare_env
  src_repo=$(restic_repo)
  [[ -n "$src_repo" ]] || die "active restic.repo is not set"
  if [[ "$dest_repo" == "$src_repo" ]]; then
    password_cleanup
    finish_transport
    location_destination_edit_end
    die "source and destination resolve to the same restic repo"
  fi
  if [[ "$dest_repo" == /* ]]; then
    local dest_fs
    dest_fs=$(findmnt -n -T "$dest_repo" -o TARGET 2>/dev/null | head -n 1 || true)
    if [[ -n "$dest_mp" && -n "$dest_fs" && "$dest_fs" == / ]]; then
      case "$dest_mp" in
        /mnt/*|/media/*|/run/media/*)
          password_cleanup
          finish_transport
          location_destination_edit_end
          die "destination '$dest_id' is not mounted; not initializing a repo on /"
          ;;
      esac
    fi
  fi
  if [[ ! -f "$dest_repo/config" ]]; then
    log "initializing restic repo at $dest_repo"
    mkdir -p "$dest_repo"
    restic_env_exec --repo "$dest_repo" init
  fi
  log "copying clones $src_repo → $dest_repo"
  restic_env_exec --repo "$dest_repo" \
    copy --from-repo "$src_repo" --from-password-file "/dev/fd/${NAS_BACKUP_PWFD}" \
    --tag identity
  password_cleanup
  finish_transport
  location_destination_edit_end
  log "copied identity clones to '$dest_id'"
}
