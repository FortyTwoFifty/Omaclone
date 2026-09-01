if [[ -n "${NAS_BACKUP_TUI_LOADED:-}" ]]; then
  return 0
fi
NAS_BACKUP_TUI_LOADED=1

tui_header() {
  require_gum
  gum style --bold --foreground 212 "${1:-Omaclone}"
}

tui_note() {
  local text="${1:-}"
  local width
  [[ -n "$text" ]] || return 0
  width="${COLUMNS:-80}"
  if (( width > 88 )); then width=88; fi
  if (( width < 40 )); then width=40; fi
  if command -v gum >/dev/null 2>&1; then
    gum style --foreground 245 --width "$width" "$text"
  else
    printf '%s\n' "$text"
  fi
}

tui_error() {
  if have gum; then
    gum style --foreground 196 "$1" >&2
  else
    printf '%s\n' "$1" >&2
  fi
}

tui_confirm() {
  gum confirm "$1"
}

# One plain-text hint per line. No markdown, no titles — those stack above
# the next gum choose and read like a README pasted into the wizard.
tui_brief() {
  local line
  shift || true
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[$' \t']/}" ]] && continue
    tui_note "$line"
  done
}

tui_brief_file() {
  local name="${1:-}"
  local file
  [[ -n "$name" ]] || return 0
  if [[ "$name" == /* ]]; then
    file="$name"
  else
    file="${NAS_BACKUP_ROOT:-}/briefs/${name}.txt"
  fi
  [[ -f "$file" ]] || return 0
  tui_brief < "$file"
}

tui_brief_from_backend() {
  local kind="${1:-}" name="${2:-}"
  local body rc=0
  [[ -n "$kind" && -n "$name" ]] || return 0
  if declare -F nas_backup_backend_run >/dev/null 2>&1; then
    body=$(nas_backup_backend_run "$kind" "$name" brief) || rc=$?
    if (( rc == 0 )); then
      if [[ -n "$body" ]]; then
        tui_brief <<< "$body"
      fi
      return 0
    fi
    if (( rc == 2 )); then
      tui_brief_file "secrets-${name}"
      tui_brief_file "$name"
      return 0
    fi
  fi
  tui_brief_file "secrets-${name}"
  tui_brief_file "$name"
}

restic_json_progress() {
  local line typ pct bytes total files
  local last_draw=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    typ=$(printf '%s' "$line" | jq -r '.message_type // empty' 2>/dev/null) || continue
    case "$typ" in
      status)
        pct=$(printf '%s' "$line" | jq -r '(.percent_done // 0) * 100')
        bytes=$(printf '%s' "$line" | jq -r '.bytes_done // 0')
        total=$(printf '%s' "$line" | jq -r '.total_bytes // 0')
        files=$(printf '%s' "$line" | jq -r '.files_done // 0')
        local now
        now=$(date +%s)
        if (( now > last_draw )); then
          printf '\r  %5.1f%%  %s / %s  files %s    ' \
            "$pct" "$(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes")" \
            "$(numfmt --to=iec "$total" 2>/dev/null || echo "$total")" \
            "$files" >&2
          last_draw=$now
        fi
        ;;
      summary)
        printf '\n' >&2
        printf '%s' "$line" | jq -r '"  snapshot \(.snapshot_id // "ok")  \(.files_new // 0) new / \(.files_changed // 0) changed  \(.data_added // 0) bytes added"' >&2 || true
        ;;
      error)
        printf '\n' >&2
        printf '%s' "$line" | jq -r '"restic error: \(.message // .)"' >&2 || printf '%s\n' "$line" >&2
        ;;
    esac
  done
}
