tui_header() {
  require_gum
  gum style --bold --foreground 212 "${1:-Omaclone}"
}

tui_note() {
  if have gum; then
    gum style --foreground 245 "$1"
  else
    printf '%s\n' "$1"
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
