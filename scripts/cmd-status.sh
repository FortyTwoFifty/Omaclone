#!/usr/bin/env bash
# Sourced by scripts/omaclone — not a standalone entrypoint.
set +o history 2>/dev/null || true
unset HISTFILE
set +x +v
set -euo pipefail

choose_retention_preset() {
  local header="${1:-How long should clones be kept?}"
  local current id lines=()
  current=$(retention_preset)
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if [[ "$id" == "$current" ]]; then
      lines+=("$id — $(retention_label "$id") (current)")
    else
      lines+=("$id — $(retention_label "$id")")
    fi
  done < <(retention_ids)
  require_gum
  local picked
  picked=$(printf '%s\n' "${lines[@]}" | gum choose --header="$header") || return 1
  printf '%s\n' "${picked%% *}"
}

cmd_retention() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    ""|show)
      printf 'preset: %s\nkeep: %s\n' "$(retention_preset)" "$(retention_label)"
      ;;
    set)
      local preset="${1:-}" yes=0
      shift || true
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) yes=1 ;;
          *) die "unknown retention option: $1" ;;
        esac
        shift
      done
      if [[ -z "$preset" ]]; then
        preset=$(choose_retention_preset "Choose a keep plan")
      fi
      local known=0 id
      while IFS= read -r id; do
        [[ "$id" == "$preset" ]] && known=1
      done < <(retention_ids)
      (( known )) || die "unknown retention preset: $preset (last-5|week|month|quarter|year|standard)"
      local current
      current=$(retention_preset)
      if [[ "$preset" == "$current" ]]; then
        tui_note "Already keeping: $(retention_label "$preset")"
        return 0
      fi
      if (( ! yes )); then
        require_gum
        tui_note "Current: $(retention_label "$current")"
        tui_note "New:     $(retention_label "$preset")"
        tui_confirm "Apply this plan and prune clones that fall outside it?" || die "aborted"
      fi
      config_set retention.preset "$preset"
      log "retention set to $preset ($(retention_label "$preset"))"
      local cur_rank new_rank
      cur_rank=$(retention_rank "$current")
      new_rank=$(retention_rank "$preset")
      if (( new_rank < cur_rank )); then
        cmd_prune
      else
        log "keep plan widened; not pruning existing clones"
      fi
      ;;
    *)
      die "usage: omaclone retention [show|set PRESET] [--yes]"
      ;;
  esac
}

cmd_status() {
  local json=0
  case "${1:-}" in
    --ack) write_issue_ack; return 0 ;;
    --json) json=1 ;;
    "" ) ;;
    *) die "usage: omaclone status [--json|--ack]" ;;
  esac
  local repo transport secrets ready=false status="unknown" message="" unix=0 reason=""
  repo=$(config_get restic.repo)
  transport=$(config_get transport.backend)
  secrets=$(config_get secrets.backend)
  if [[ -n "$transport" ]] && nas_backup_backend_run transport "$transport" ready >/dev/null 2>&1; then
    ready=true
  fi
  local last="" loc_id=""
  loc_id=$(location_active_id 2>/dev/null || true)
  if [[ -n "$loc_id" && -f "$NAS_BACKUP_STATE_DIR/last-result-${loc_id}.json" ]]; then
    last="$NAS_BACKUP_STATE_DIR/last-result-${loc_id}.json"
  elif [[ -f "$NAS_BACKUP_STATE_DIR/last-result.json" ]]; then
    local _file_loc
    _file_loc=$(jq -r '.location // ""' "$NAS_BACKUP_STATE_DIR/last-result.json" 2>/dev/null || true)
    if [[ -z "$_file_loc" || "$_file_loc" == "$loc_id" ]]; then
      last="$NAS_BACKUP_STATE_DIR/last-result.json"
    fi
  elif [[ ! -f "$NAS_BACKUP_STATE_DIR/last-result-${loc_id}.json" ]]; then
    if [[ -n "$loc_id" ]]; then
      for _legacy in "${_legacy_state_dirs[@]:-}"; do
        if [[ -f "$_legacy/last-result-${loc_id}.json" ]]; then
          last="$_legacy/last-result-${loc_id}.json"
          break
        fi
      done
    fi
  fi
  if [[ -z "$last" ]]; then
    :
  elif [[ -f "$last" ]]; then
    status=$(jq -r '.status // "unknown"' "$last" 2>/dev/null || echo unknown)
    message=$(jq -r '.message // empty' "$last" 2>/dev/null || true)
    unix=$(jq -r '.unix // 0' "$last" 2>/dev/null || echo 0)
    reason=$(jq -r '.reason // empty' "$last" 2>/dev/null || true)
  elif [[ -z "$repo" ]]; then
    status=unconfigured
  fi
  local age="$status"
  if [[ "${unix:-0}" -gt 0 ]]; then
    local delta=$(( $(date +%s) - unix ))
    if (( delta < 90 )); then age="just now"
    elif (( delta < 3600 )); then age="$((delta / 60))m ago"
    elif (( delta < 86400 )); then age="$((delta / 3600))h ago"
    else age="$((delta / 86400))d ago"
    fi
  fi
  if [[ "$status" == skip && "$age" == skip ]]; then
    age="skipped"
  fi
  local ok=false
  [[ "$status" == ok ]] && ok=true
  local configured=false setupComplete=false
  [[ -n "$repo" ]] && configured=true
  if setup_is_configured && ! setup_is_unfinished; then
    setupComplete=true
  fi
  local acked=false
  if issue_is_acked "${unix:-0}" "$loc_id"; then
    acked=true
  fi
  local loc_json connected=false watchPath="" _conn=""
  loc_json=$(location_list_json 2>/dev/null || echo '[]')
  [[ "$loc_json" == \[* ]] || loc_json='[]'
  _conn=$(printf '%s' "$loc_json" | jq -r --arg id "$loc_id" \
    'map(select(.id == $id)) | if length == 0 then empty else (.[0].connected | tostring) end' 2>/dev/null || true)
  if [[ "$_conn" == true ]]; then
    connected=true
  elif [[ "$_conn" == false ]]; then
    connected=false
  else
    connected=$ready
  fi
  watchPath=$(printf '%s' "$loc_json" | jq -r --arg id "$loc_id" '
    (map(select(.id == $id)) | .[0]) as $l
    | if ($l | type) != "object" then empty
      elif $l.backend == "disk" and ($l.uuid | tostring | length) > 0
        then "/dev/disk/by-uuid/\($l.uuid)"
      else empty end
  ' 2>/dev/null || true)
  local watchPaths='[]'
  watchPaths=$(printf '%s' "$loc_json" | jq -c '
    [ .[]
      | select(.source != "discovered")
      | if .backend == "disk" and (.uuid | tostring | length) > 0
        then "/dev/disk/by-uuid/\(.uuid)"
        else empty end
    ] | unique
  ' 2>/dev/null || true)
  [[ "$watchPaths" == \[* ]] || watchPaths='[]'

  local severity=ok issueTitle="" issueKind=""
  if [[ -z "$repo" ]]; then
    severity=ok
    issueTitle=""
    [[ -n "$message" ]] || message="Run Set up Omaclone to create or restore a clone."
  elif setup_is_unfinished && [[ "$acked" != true ]]; then
    severity=warning
    issueTitle="Setup unfinished"
    [[ -n "$message" ]] || message="Continue setup to finish this location."
  elif [[ "$connected" != true ]]; then
    if location_expected_offline "$loc_id"; then
      severity=ok
      issueTitle=""
      [[ -n "$message" ]] || message="USB not plugged in"
    elif [[ "$acked" != true ]]; then
      severity=warning
      issueTitle="Location not connected"
      [[ -n "$message" ]] || message="Plug in or mount the clone location, then retry."
    fi
  elif [[ "$ready" != true && ( "$transport" == s3 || "$transport" == sftp ) && "$acked" != true ]]; then
    severity=warning
    issueTitle="Keys missing"
    [[ -n "$message" ]] || message="Unlock the Omaclone keyring or re-enter $transport keys, then retry."
  elif [[ "$status" == skip ]] && issue_is_password_skip "$reason" "$message"; then
    if [[ "$acked" != true ]]; then
      severity=warning
      issueKind=password_locked
      issueTitle="Password manager locked"
      if [[ "$secrets" == keyring ]] && keyring_retry_active; then
        message="The last automatic clone did not run because the keyring was locked. It will run when you unlock it."
      else
        message="The last automatic clone did not run because the password manager was locked. Store the restic password in the keyring for unattended clones, or clone from the pane after signing in."
      fi
    fi
  elif [[ "$status" == skip ]]; then
    if issue_is_disconnect "$message" "$transport"; then
      severity=ok
      issueTitle=""
    elif [[ "$acked" != true ]]; then
      severity=warning
      issueTitle="Clone skipped"
      [[ -n "$message" ]] || message="Automatic clone was skipped."
    fi
  elif [[ "$status" == fail && "$acked" != true ]]; then
    severity=error
    issueTitle="Last clone failed"
    if [[ -z "$message" || "$message" == restic\ backup\ exited* ]]; then
      message="The last identity clone failed. Retry from this pane, or run: omaclone clone"
    fi
  fi
  local snap_count="" restore_bytes=0 packed_bytes=0 lc
  read -r _ restore_bytes packed_bytes < <(read_repo_stats)
  [[ "$restore_bytes" =~ ^[0-9]+$ ]] || restore_bytes=0
  [[ "$packed_bytes" =~ ^[0-9]+$ ]] || packed_bytes=0
  if [[ "$connected" != true ]]; then
    restore_bytes=0
    packed_bytes=0
  elif lc=$(local_snapshot_count 2>/dev/null); then
    snap_count="$lc"
  elif [[ -n "$loc_id" && -f "$NAS_BACKUP_STATE_DIR/repo-stats-${loc_id}.json" ]]; then
    # Remote repos (S3/SFTP) have no local snapshots/ dir. Use the count
    # written after clone/prune — do not call restic snapshots on status polls.
    local stats_file="$NAS_BACKUP_STATE_DIR/repo-stats-${loc_id}.json"
    snap_count=$(jq -r '.snapshotCount // empty' "$stats_file" 2>/dev/null || true)
    restore_bytes=$(jq -r '.restoreSizeBytes // .repoSizeBytes // 0' "$stats_file" 2>/dev/null || echo 0)
    packed_bytes=$(jq -r '.packedSizeBytes // 0' "$stats_file" 2>/dev/null || echo 0)
    [[ "$restore_bytes" =~ ^[0-9]+$ ]] || restore_bytes=0
    [[ "$packed_bytes" =~ ^[0-9]+$ ]] || packed_bytes=0
  fi
  [[ "$snap_count" =~ ^[0-9]+$ ]] || snap_count=""
  local snap_json=-1
  [[ -n "$snap_count" ]] && snap_json="$snap_count"
  local size_text packed_text
  size_text=$(human_bytes "$restore_bytes")
  packed_text=$(human_bytes "$packed_bytes")
  local keep_id keep_label
  keep_id=$(retention_preset)
  keep_label=$(retention_label "$keep_id")
  local _loc_id loc_label loc_sched
  _loc_id=$(location_active_id)
  loc_label=$(location_get "$_loc_id" label "$_loc_id")
  loc_sched=$(location_get "$_loc_id" schedule on)
  if (( json )); then
    jq -n \
      --argjson ok "$ok" \
      --argjson configured "$configured" \
      --argjson transportReady "$ready" \
      --arg repo "$repo" \
      --arg transport "$transport" \
      --arg secrets "$secrets" \
      --arg lastStatus "$status" \
      --arg lastError "$message" \
      --argjson lastBackupUnix "${unix:-0}" \
      --arg statusText "$age" \
      --argjson snapshotCount "$snap_json" \
      --argjson repoSizeBytes "${restore_bytes:-0}" \
      --arg repoSizeText "$size_text" \
      --argjson packedSizeBytes "${packed_bytes:-0}" \
      --arg packedSizeText "$packed_text" \
      --arg retentionPreset "$keep_id" \
      --arg retentionLabel "$keep_label" \
      --arg locationId "$loc_id" \
      --arg locationLabel "$loc_label" \
      --arg locationSchedule "$loc_sched" \
      --argjson locations "$loc_json" \
      --argjson setupComplete "$setupComplete" \
      --argjson connected "$connected" \
      --arg watchPath "$watchPath" \
      --argjson watchPaths "$watchPaths" \
      --arg severity "$severity" \
      --arg issueTitle "$issueTitle" \
      --arg issueKind "$issueKind" \
      --argjson issueAcked "$acked" \
      '{ok:$ok,configured:$configured,transportReady:$transportReady,repo:$repo,transport:$transport,secrets:$secrets,lastStatus:$lastStatus,lastError:$lastError,lastBackupUnix:$lastBackupUnix,statusText:$statusText,snapshotCount:$snapshotCount,repoSizeBytes:$repoSizeBytes,repoSizeText:$repoSizeText,packedSizeBytes:$packedSizeBytes,packedSizeText:$packedSizeText,retentionPreset:$retentionPreset,retentionLabel:$retentionLabel,locationId:$locationId,locationLabel:$locationLabel,locationSchedule:$locationSchedule,locations:$locations,setupComplete:$setupComplete,connected:$connected,watchPath:$watchPath,watchPaths:$watchPaths,severity:$severity,issueTitle:$issueTitle,issueKind:$issueKind,issueAcked:$issueAcked}'
  else
    local setup_text="complete"
    [[ "$setupComplete" == false ]] && setup_text="unfinished"
    printf 'ok: %s\nconfigured: %s\ntransportReady: %s\nrepo: %s\ntransport: %s\nsecrets: %s\nlastStatus: %s\nlastError: %s\nstatusText: %s\nclones: %s\nstorage: %s\npacked: %s\nkeep: %s\nlocation: %s (%s, %s)\nsetupComplete: %s\nconnected: %s\nwatchPath: %s\nseverity: %s\nissue: %s\n' \
      "$ok" "$configured" "$ready" "$repo" "$transport" "$secrets" "$status" "$message" "$age" \
      "${snap_count:--}" "$size_text" "$packed_text" "$keep_label" \
      "$loc_id" "$loc_label" "$( [[ "$loc_sched" == on ]] && echo daily || echo manual )" \
      "$setup_text" "$connected" "$watchPath" "$severity" "$issueTitle"
  fi
}

cmd_location() {
  migrate_locations
  local want_json=0
  local args=()
  local a
  for a in "$@"; do
    if [[ "$a" == --json ]]; then
      want_json=1
    else
      args+=("$a")
    fi
  done
  set -- "${args[@]}"
  local sub="${1:-list}"
  shift || true
  case "$sub" in
    list|"")
      local json
      json=$(location_list_json)
      if (( want_json )) || [[ "${1:-}" == --json ]]; then
        printf '%s\n' "$json"
        return 0
      fi
      printf '%s\n' "$json" | jq -r '.[] | [
          (if .active then "*" else " " end),
          .id,
          .label,
          .backend,
          (if .schedule == "on" then "daily" else "manual" end),
          (if .connected then "connected" else "offline" end),
          .source
        ] | @tsv' | column -t -s $'\t'
      ;;
    add)
      require_gum
      local prev
      prev=$(location_active_id)
      _setup_pick_destination
      _setup_init_step || return
      _setup_register_location
      local id="$LOCATION_LAST_ID"
      if [[ -n "$prev" && "$prev" != "$id" ]]; then
        if tui_confirm "Make '$id' the active location now?"; then
          location_activate "$id"
        else
          tui_note "Keeping '$prev' as the active location (daily clones follow that one)."
          location_activate "$prev"
        fi
      else
        location_schedule_apply "$id"
      fi
      ;;
    switch)
      local id="${1:-}" yes=0
      shift || true
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) yes=1 ;;
          *) die "unknown location switch option: $1" ;;
        esac
        shift
      done
      local json
      json=$(location_list_json)
      if [[ -z "$id" ]]; then
        require_gum
        local lines picked
        lines=$(printf '%s' "$json" | jq -r '.[] | "\(.id) — \(.label)  [\(.backend), \(if .schedule=="on" then "daily" else "manual" end), \(if .connected then "connected" else "offline" end)]\(if .active then "  (active)" else "" end)"')
        picked=$(printf '%s\n' "$lines" | gum choose --header="Switch clone location")
        id="${picked%% — *}"
      fi
      [[ -n "$id" ]] || die "no location selected"
      if [[ "$id" == discovered:* ]]; then
        _location_import_discovered "$id" "$json"
        return
      fi
      location_has "$id" || die "unknown location: $id"
      if [[ "$id" == "$(location_active_id)" ]]; then
        location_schedule_apply "$id"
        return 0
      fi
      if (( ! yes )); then
        tui_confirm "Switch active clone location to '$id'?" || die "aborted"
      fi
      location_activate "$id"
      if (( ! yes )); then
        tui_note "Active location: $id ($(location_get "$id" label)) — $( [[ "$(location_get "$id" schedule)" == on ]] && echo "daily clones on" || echo "manual clones only" )"
      fi
      ;;
    remove|forget)
      local id="${1:-}" yes=0
      shift || true
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) yes=1 ;;
          *) die "unknown location remove option: $1" ;;
        esac
        shift
      done
      if [[ -z "$id" ]]; then
        require_gum
        local json lines picked
        json=$(location_list_json)
        lines=$(printf '%s' "$json" | jq -r '.[] | select(.source != "discovered") | "\(.id) — \(.label)  [\(.backend), \(if .connected then "connected" else "offline" end)]"')
        [[ -n "$lines" ]] || die "no saved locations"
        picked=$(printf '%s\n' "$lines" | gum choose --header="Forget which location?") || die "aborted"
        id="${picked%% — *}"
      fi
      [[ -n "$id" ]] || die "no location selected"
      location_has "$id" || die "unknown location: $id"
      if (( ! yes )); then
        tui_confirm "Forget location '$id'? The drive is not erased." || die "aborted"
      fi
      location_drop "$id"
      ;;
    schedule)
      local target="${1:-}" val="${2:-}"
      if [[ "$target" == on || "$target" == off ]]; then
        val="$target"
        target=$(location_active_id)
      elif [[ -z "$target" ]]; then
        target=$(location_active_id)
      fi
      [[ -n "$target" ]] || die "no active location; run: omaclone setup"
      location_has "$target" || die "unknown location: $target"
      if [[ -z "$val" ]]; then
        printf '%s\n' "$(location_get "$target" schedule on)"
        return 0
      fi
      [[ "$val" == on || "$val" == off ]] || die "usage: omaclone location schedule [ID] on|off"
      location_set "$target" schedule "$val"
      if [[ "$target" == "$(location_active_id)" ]]; then
        location_schedule_apply "$target"
      fi
      log "location '$target' automatic clones: $val"
      ;;
    *)
      die "usage: omaclone location [list|add|switch ID|remove ID|schedule [ID] on|off] [--json] [--yes]"
      ;;
  esac
}

_location_import_discovered() {
  local did="$1" json="$2"
  local mp cfg
  mp="${did#discovered:}"
  cfg=$(printf '%s' "$json" | jq -r --arg id "$did" '.[] | select(.id==$id) | .config // empty')
  [[ -n "$mp" && -d "$mp" ]] || die "discovered location is not mounted"
  local backend="disk"
  if [[ -n "$cfg" && -f "$cfg" ]]; then
    backend=$(python3 "$ROOT/scripts/config.py" "$cfg" get transport.backend disk)
    config_set transport.backend "$backend"
    config_set transport.uri "$(python3 "$ROOT/scripts/config.py" "$cfg" get transport.uri)"
    config_set transport.mountpoint "$(python3 "$ROOT/scripts/config.py" "$cfg" get transport.mountpoint "$mp")"
    config_set restic.repo "$(python3 "$ROOT/scripts/config.py" "$cfg" get restic.repo "$mp/repo")"
    config_set transport.uuid "$(python3 "$ROOT/scripts/config.py" "$cfg" get transport.uuid)"
    config_set transport.mode "$(python3 "$ROOT/scripts/config.py" "$cfg" get transport.mode cold)"
    config_set destination.profile "$(python3 "$ROOT/scripts/config.py" "$cfg" get destination.profile disk)"
  else
    config_set transport.backend disk
    config_set transport.mountpoint "$mp"
    config_set restic.repo "$mp/repo"
    config_set transport.mode cold
    config_set destination.profile disk
  fi
  local id uuid mode label schedule existing_label
  uuid=$(config_get transport.uuid)
  mode=$(config_get transport.mode)
  [[ -n "$mode" ]] || mode=cold
  id=""
  if [[ -n "$uuid" ]]; then
    id=$(location_find_id_by_uuid "$uuid" || true)
  fi
  [[ -n "$id" ]] || id=$(location_slug "usb")
  existing_label=$(location_get "$id" label "")
  label=$(location_import_label "$mp" "$existing_label" "$backend" "$mode" "$uuid")
  schedule=$(location_get "$id" schedule "")
  [[ -n "$schedule" ]] || schedule=off
  location_save_current "$id" "$label" "$schedule"
  location_activate "$id"
}

cmd_wait_keyring() {
  local backend
  backend=$(config_get secrets.backend)
  [[ "$backend" == keyring ]] || exit 0
  local deadline=$((SECONDS + 20 * 3600))
  while (( SECONDS < deadline )); do
    if nas_backup_backend_run secrets keyring get >/dev/null 2>&1; then
      exec "$ROOT/scripts/omaclone" clone --after-unlock
    fi
    if command -v gdbus >/dev/null 2>&1; then
      timeout 30 gdbus monitor --session --dest org.freedesktop.secrets >/dev/null 2>&1 || true
    else
      sleep 15
    fi
  done
  log "keyring did not unlock in time; the next daily clone will try again"
  exit 0
}

cmd_install() {
  mkdir -p "$HOME/.local/bin" "$HOME/.config/omarchy/plugins"
  omaclone_link_cli
  omaclone_link_plugin
  omaclone_install_menu

  if [[ "${OMACLONE_SKIP_SYSTEMD:-}" != 1 ]]; then
    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"
    systemctl --user disable --now nas-backup.timer nas-backup-prune.timer 2>/dev/null || true
    rm -f "$unit_dir/nas-backup.service" "$unit_dir/nas-backup.timer" \
      "$unit_dir/nas-backup-prune.service" "$unit_dir/nas-backup-prune.timer"
    cp "$ROOT/systemd/omaclone.service" "$unit_dir/omaclone.service"
    cp "$ROOT/systemd/omaclone.timer" "$unit_dir/omaclone.timer"
    cp "$ROOT/systemd/omaclone-prune.timer" "$unit_dir/omaclone-prune.timer"
    cp "$ROOT/systemd/omaclone-prune.service" "$unit_dir/omaclone-prune.service"
    cp "$ROOT/systemd/omaclone-keyring-retry.service" "$unit_dir/omaclone-keyring-retry.service"
    systemctl --user daemon-reload
    location_schedule_apply
    loginctl enable-linger "$USER" 2>/dev/null || true
    config_set install.linger 1

    if have omarchy; then
      omarchy plugin enable "$PLUGIN_ID" --section right --after omarchy.tray 2>/dev/null || \
        omarchy plugin enable "$PLUGIN_ID" --section right 2>/dev/null || \
        omarchy-shell shell enablePlugin "$PLUGIN_ID" '{}' 2>/dev/null || \
        log "enable the bar widget with: omarchy plugin enable $PLUGIN_ID"
      omarchy menu refresh 2>/dev/null || true
      omarchy-shell shell rescanPlugins 2>/dev/null || true
    fi
  fi
  if [[ "${OMACLONE_SKIP_SYSTEMD:-}" != 1 && "$(config_get transport.backend)" == nfs ]]; then
    source "$ROOT/scripts/nfs-lib.sh"
    nfs_upgrade_existing_units "$(config_get transport.uri)" "$(config_get transport.mountpoint)" || true
    nfs_remount_hardening "$(config_get transport.mountpoint)"
  fi
  log "installed: ~/.local/bin/omaclone and plugin $PLUGIN_ID"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) log "note: add ~/.local/bin to PATH so new terminals find omaclone" ;;
  esac
}

cmd_uninstall() {
  if [[ "${OMACLONE_SKIP_SYSTEMD:-}" != 1 ]]; then
    if have omarchy; then
      omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || \
        omarchy-shell shell setPluginEnabled "$PLUGIN_ID" false >/dev/null 2>&1 || true
    fi
    local unit_dir="$HOME/.config/systemd/user"
    systemctl --user disable --now omaclone.timer omaclone-prune.timer \
      omaclone.service omaclone-prune.service omaclone-keyring-retry.service 2>/dev/null || true
    rm -f "$unit_dir/omaclone.service" "$unit_dir/omaclone.timer" \
      "$unit_dir/omaclone-prune.service" "$unit_dir/omaclone-prune.timer" \
      "$unit_dir/omaclone-keyring-retry.service"
    systemctl --user daemon-reload 2>/dev/null || true
    if [[ "$(config_get install.linger)" == 1 ]]; then
      loginctl disable-linger "$USER" 2>/dev/null || true
      config_set install.linger ""
    elif is_tty && have gum; then
      if tui_confirm --default=false "Disable lingering login so timers do not run after logout?"; then
        loginctl disable-linger "$USER" 2>/dev/null || true
      fi
    else
      log "lingering login was not disabled; to disable: loginctl disable-linger $USER"
    fi
  fi
  omaclone_unlink_cli
  omaclone_unlink_plugin
  omaclone_uninstall_menu
  log "removed PATH command, timers, plugin symlink, and Super+Space menu entries"
  log "config (~/.config/omaclone) and clones were not deleted"
  log "NFS/disk systemd mounts in /etc/systemd/system were not removed (needs sudo)"
  log "if the bar widget is still a git clone: omarchy plugin remove $PLUGIN_ID"
}

cmd_doctor() {
  echo "user: $(id)"
  echo "config: $NAS_BACKUP_CONFIG"
  echo "locations: ids=$(config_get locations.ids) active=$(location_active_id)"
  location_list_json 2>/dev/null | jq -r '.[] | "  \(.id): \(.label) [\(.backend) \(.schedule) \(if .connected then "up" else "down" end)]\(if .active then " *" else "" end)"' 2>/dev/null || true
  echo "destination: profile=$(config_get destination.profile) vendor=$(config_get destination.vendor)"
  echo "transport: $(config_get transport.backend)  uri=$(config_get transport.uri)"
  echo "mountpoint: $(config_get transport.mountpoint)"
  echo "restic.repo: $(config_get restic.repo)"
  echo "secrets: $(config_get secrets.backend)"
  local vault_item_field
  vault_item_field=$(config_get secrets.vault)
  [[ -n "$vault_item_field" ]] && echo "secrets/vault: $vault_item_field"
  vault_item_field=$(config_get secrets.item)
  [[ -n "$vault_item_field" ]] && echo "secrets/item: $vault_item_field"
  vault_item_field=$(config_get secrets.field)
  [[ -n "$vault_item_field" ]] && echo "secrets/field: $vault_item_field"

  local backend
  backend=$(config_get secrets.backend)
  case "$backend" in
    pass-cli)
      if pass-cli info >/dev/null 2>&1; then
        echo "pass-cli: signed in"
      else
        echo "pass-cli: not signed in (pass-cli login)"
      fi
      ;;
    1password)
      if op account get >/dev/null 2>&1 || op whoami >/dev/null 2>&1; then
        echo "op: signed in"
      else
        echo "op: not signed in (op signin)"
      fi
      ;;
  esac

  if setup_is_unfinished; then
    echo "setup: unfinished — run: omaclone setup"
  fi

  local mp repo backend opts plugin_dest pv rv
  mp=$(config_get transport.mountpoint)
  repo=$(config_get restic.repo)
  backend=$(config_get transport.backend)
  if [[ "$backend" == nfs && -n "$mp" ]]; then
    if findmnt -n -t nfs,nfs4 "$mp" >/dev/null 2>&1; then
      echo "mounted: $(findmnt -n -t nfs,nfs4 -o SOURCE,FSTYPE "$mp" | awk 'NR==1 { print; exit }')"
      opts=$(findmnt -n -t nfs,nfs4 -o OPTIONS "$mp" | awk 'NR==1 { print; exit }')
      echo "options: $opts"
      if [[ "$opts" != *nosuid* || "$opts" != *nodev* || "$opts" != *noexec* ]]; then
        echo "mount flags: missing nosuid,nodev,noexec — run: omaclone install"
      fi
      echo "dir: $(stat -c 'uid=%u gid=%g mode=%A' "$mp" 2>/dev/null || echo missing)"
      if dir_is_writable "$mp"; then
        echo "writable: yes"
      else
        echo "writable: NO"
        explain_nfs_uid_mismatch "$mp"
      fi
    else
      echo "mounted: no"
    fi
  elif [[ -n "$mp" ]] && findmnt -n "$mp" >/dev/null 2>&1; then
    echo "mounted: $(findmnt -n -o SOURCE,FSTYPE "$mp" | awk 'NR==1 { print; exit }')"
    echo "dir: $(stat -c 'uid=%u gid=%g mode=%A' "$mp" 2>/dev/null || echo missing)"
    if dir_is_writable "$mp"; then
      echo "writable: yes"
    else
      echo "writable: NO"
    fi
  elif [[ "$backend" == s3 || "$backend" == sftp ]]; then
    echo "mounted: n/a (remote transport)"
    if nas_backup_backend_run transport "$backend" ready; then
      echo "ready: yes"
    else
      echo "ready: NO"
    fi
  else
    echo "mounted: no"
  fi
  if [[ "$repo" == s3:* || "$repo" == sftp:* ]]; then
    echo "restic repo: $repo"
  elif [[ -f "$repo/config" ]]; then
    echo "restic config: present at $repo"
  else
    echo "restic config: absent at $repo"
  fi
  plugin_dest=$(omaclone_plugin_dest)
  if [[ -f "$plugin_dest/manifest.json" && -f "$ROOT/manifest.json" ]]; then
    pv=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$plugin_dest/manifest.json" 2>/dev/null || true)
    rv=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$ROOT/manifest.json" 2>/dev/null || true)
    if [[ -n "$pv" && -n "$rv" && "$pv" != "$rv" ]]; then
      echo "plugin copy at $plugin_dest is $pv; this tree is $rv"
      echo "the daily timer uses ~/.local/bin/omaclone — run: omaclone install"
    fi
  fi
}
