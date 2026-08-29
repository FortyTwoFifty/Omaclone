if [[ -n "${NAS_BACKUP_BACKEND_LOADED:-}" ]]; then
  return 0
fi
NAS_BACKUP_BACKEND_LOADED=1

NAS_BACKUP_USER_BACKENDS="${NAS_BACKUP_USER_BACKENDS:-$NAS_BACKUP_USER_CONFIG_DIR/backends}"

nas_backup_backend_dirs() {
  local kind="$1"
  printf '%s\n' "$NAS_BACKUP_USER_BACKENDS/$kind" "$NAS_BACKUP_ROOT/backends/$kind"
}

nas_backup_backend_find() {
  local kind="$1" name="$2" dir
  for dir in $(nas_backup_backend_dirs "$kind"); do
    if [[ -x "$dir/$name" ]]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done
  return 1
}

nas_backup_backend_names() {
  local kind="$1" dir name
  declare -A seen=()
  for dir in $(nas_backup_backend_dirs "$kind"); do
    [[ -d "$dir" ]] || continue
    for name in "$dir"/*; do
      [[ -e "$name" ]] || continue
      local base
      base=$(basename "$name")
      [[ "$base" == example ]] && continue
      seen["$base"]=1
    done
  done
  local k
  for k in "${!seen[@]}"; do
    printf '%s\n' "$k"
  done | LC_ALL=C sort
}

nas_backup_backend_run() {
  local kind="$1" name="$2" verb="$3"
  shift 3 || true
  local path
  path=$(nas_backup_backend_find "$kind" "$name") || {
    log "backend not found: $kind/$name"
    return 1
  }
  export NAS_BACKUP_CONFIG NAS_BACKUP_ROOT NAS_BACKUP_USER_CONFIG_DIR
  export NAS_BACKUP_KIND="$kind" NAS_BACKUP_BACKEND="$name"
  "$path" "$verb" "$@"
}

nas_backup_backend_available() {
  local kind="$1" name="$2"
  nas_backup_backend_run "$kind" "$name" available >/dev/null 2>&1
}

nas_backup_backend_describe() {
  local kind="$1" name="$2"
  nas_backup_backend_run "$kind" "$name" describe 2>/dev/null || printf '%s\n' "$name"
}

nas_backup_backend_available_names() {
  local kind="$1" name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if nas_backup_backend_available "$kind" "$name"; then
      printf '%s\n' "$name"
    fi
  done < <(nas_backup_backend_names "$kind")
}

nas_backup_backend_all_names() {
  local kind="$1" dir name
  declare -A seen=()
  for dir in $(nas_backup_backend_dirs "$kind"); do
    [[ -d "$dir" ]] || continue
    for name in "$dir"/*; do
      [[ -e "$name" ]] || continue
      local base
      base=$(basename "$name")
      [[ "$base" == example ]] && continue
      seen["$base"]=1
    done
  done
  local k
  for k in "${!seen[@]}"; do
    printf '%s\n' "$k"
  done | LC_ALL=C sort
}

nas_backup_backend_ensure() {
  local kind="$1" name="$2"
  if nas_backup_backend_available "$kind" "$name"; then
    return 0
  fi
  local path
  path=$(nas_backup_backend_find "$kind" "$name") || {
    log "backend not found: $kind/$name — cannot ensure CLI"
    return 1
  }
  if declare -F deps_ensure_pacman >/dev/null; then
    :
  else
    source "$NAS_BACKUP_ROOT/scripts/deps.sh" || true
  fi
  export NAS_BACKUP_CONFIG NAS_BACKUP_ROOT NAS_BACKUP_USER_CONFIG_DIR
  export NAS_BACKUP_KIND="$kind" NAS_BACKUP_BACKEND="$name"
  local rc=0
  "$path" install || rc=$?
  if (( rc == 2 )); then
    log "$kind/$name has no installer — cannot ensure CLI"
    return 1
  fi
  if (( rc != 0 )); then
    log "install failed for $kind/$name (exit $rc)"
    return 1
  fi
  if nas_backup_backend_available "$kind" "$name"; then
    return 0
  fi
  return 1
}

nas_backup_backend_choose_all() {
  local kind="$1"
  local header="${2:-Choose $kind backend}"
  shift 2 || true
  local filter=("$@")
  local names=() lines=() name desc available_label allowed
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ((${#filter[@]} > 0)); then
      allowed=0
      local f
      for f in "${filter[@]}"; do
        [[ "$name" == "$f" ]] && allowed=1 && break
      done
      (( allowed )) || continue
    fi
    names+=("$name")
    desc=$(nas_backup_backend_describe "$kind" "$name" | head -n 1)
    if nas_backup_backend_available "$kind" "$name"; then
      available_label=""
    else
      available_label=" [not installed]"
    fi
    lines+=("${names[-1]} — ${desc}${available_label}")
  done < <(nas_backup_backend_all_names "$kind")
  if ((${#names[@]} == 0)); then
    die "no $kind backends found"
  fi
  if ((${#names[@]} == 1)); then
    printf '%s\n' "${names[0]}"
    return 0
  fi
  require_gum
  local picked
  picked=$(printf '%s\n' "${lines[@]}" | gum choose --header="$header") || return 1
  printf '%s\n' "${picked%% — *}"
}

nas_backup_transport_backend_ensure() {
  local backend="$1"
  nas_backup_backend_ensure transport "$backend" || die "could not install $backend CLI"
}

nas_backup_backend_choose() {
  local kind="$1"
  local header="${2:-Choose $kind backend}"
  shift 2 || true
  local filter=("$@")
  local names=() lines=() name desc allowed
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ((${#filter[@]} > 0)); then
      allowed=0
      local f
      for f in "${filter[@]}"; do
        [[ "$name" == "$f" ]] && allowed=1 && break
      done
      (( allowed )) || continue
    fi
    names+=("$name")
    desc=$(nas_backup_backend_describe "$kind" "$name" | head -n 1)
    lines+=("$name — $desc")
  done < <(nas_backup_backend_available_names "$kind")
  if ((${#names[@]} == 0)); then
    die "no available $kind backends"
  fi
  if ((${#names[@]} == 1)); then
    printf '%s\n' "${names[0]}"
    return 0
  fi
  require_gum
  local picked
  picked=$(printf '%s\n' "${lines[@]}" | gum choose --header="$header") || return 1
  printf '%s\n' "${picked%% — *}"
}

nas_backup_transport_capabilities() {
  local backend="$1"
  local caps
  caps=$(nas_backup_backend_run transport "$backend" capabilities 2>/dev/null || true)
  caps=$(printf '%s' "$caps" | tr '\n' ' ')
  if [[ -z "${caps// /}" ]]; then
    printf '%s\n' "mount"
  else
    printf '%s\n' "$caps"
  fi
}

nas_backup_transport_has() {
  local backend="$1"
  local flag="$2"
  local caps
  caps=" $(nas_backup_transport_capabilities "$backend") "
  [[ "$caps" == *" $flag "* ]]
}
