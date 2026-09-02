#!/usr/bin/env bash
set +x +v

HYPRCTL="${HYPRCTL:-/usr/bin/hyprctl}"
JQ="${JQ:-/usr/bin/jq}"
LOG="${XDG_RUNTIME_DIR:-/tmp}/omaclone-launch-tui.log"
LAUNCHER="$(command -v omarchy-launch-floating-terminal-with-presentation 2>/dev/null || echo /usr/share/omarchy/bin/omarchy-launch-floating-terminal-with-presentation)"

debug() {
  [[ -n "${OMACLONE_DEBUG:-}" ]] || return 0
  printf '%s\n' "$*" >>"$LOG"
}

cmd=""
for _arg in "$@"; do
  cmd+=$(printf '%q ' "$_arg")
done
cmd="${cmd% }"
[[ -n "$cmd" ]] || exit 1

if [[ -n "${OMACLONE_DEBUG:-}" ]]; then
  {
    echo "cmd=$cmd"
    echo "hyprland=${HYPRLAND_INSTANCE_SIGNATURE:-missing}"
    echo "wayland=${WAYLAND_DISPLAY:-missing}"
  } >"$LOG"
fi

orig_follow=$($HYPRCTL getoption input:follow_mouse -j 2>/dev/null | $JQ -r '.int // 1')
[[ "$orig_follow" == [0-9]* ]] || orig_follow=1

set_follow_mouse() {
  $HYPRCTL eval "hl.config({ input = { follow_mouse = $1 } })" >/dev/null 2>&1 || true
}

restore_follow_mouse() {
  set_follow_mouse "$orig_follow"
}
trap restore_follow_mouse EXIT

hide_cursor() {
  $HYPRCTL dispatch 'hl.dsp.send_key_state({ mods = "", key = "SHIFT", state = "down" })' >/dev/null 2>&1 || true
  $HYPRCTL dispatch 'hl.dsp.send_key_state({ mods = "", key = "SHIFT", state = "up" })' >/dev/null 2>&1 || true
}

warp_to_screen_center() {
  local pos cx cy center
  pos=$($HYPRCTL cursorpos -j 2>/dev/null || echo '{"x":0,"y":0}')
  center=$($HYPRCTL monitors -j 2>/dev/null | $JQ -r --argjson pos "$pos" '
    def layout:
      ((.transform // 0) % 4) as $t
      | (if $t == 1 or $t == 3 then {w: (.height / .scale), h: (.width / .scale)}
         else {w: (.width / .scale), h: (.height / .scale)} end)
        + {x: .x, y: .y, focused: .focused};
    ([.[] | layout | . + {x2: (.x + .w), y2: (.y + .h)}] ) as $ms
    | ($ms
        | map(select($pos.x >= .x and $pos.x < .x2 and $pos.y >= .y and $pos.y < .y2))
        | first)
      // ($ms | map(select(.focused == true)) | first)
      // $ms[0]
    | "\((.x + .w / 2) | floor) \((.y + .h / 2) | floor)"
  ' 2>/dev/null || true)
  read -r cx cy <<<"$center"
  [[ -n "$cx" && -n "$cy" ]] || return 0
  debug "warp $cx $cy"
  $HYPRCTL dispatch "hl.dsp.cursor.move({ x = $cx, y = $cy })" >/dev/null 2>&1 || true
}

focus_window() {
  $HYPRCTL dispatch "hl.dsp.focus({ window = \"address:$1\" })" >/dev/null 2>&1 || true
}

window_still_mapped() {
  $HYPRCTL clients -j 2>/dev/null | $JQ -e --arg a "$1" '.[] | select(.address == $a and .mapped == true)' >/dev/null 2>&1
}

cursor_moved() {
  local pos x y
  pos=$($HYPRCTL cursorpos -j 2>/dev/null || echo '{}')
  x=$($JQ -r '.x // 0' <<<"$pos")
  y=$($JQ -r '.y // 0' <<<"$pos")
  $JQ -ne --argjson sx "$start_x" --argjson sy "$start_y" --argjson x "$x" --argjson y "$y" \
    '(($x - $sx) | fabs) > 4 or (($y - $sy) | fabs) > 4' >/dev/null 2>&1
}

set_follow_mouse 0
warp_to_screen_center
hide_cursor

start_pos=$($HYPRCTL cursorpos -j 2>/dev/null || echo '{}')
start_x=$($JQ -r '.x // 0' <<<"$start_pos")
start_y=$($JQ -r '.y // 0' <<<"$start_pos")

before=$($HYPRCTL clients -j 2>/dev/null | $JQ -c '[.[] | select(.class == "org.omarchy.terminal") | .address]' 2>/dev/null || echo '[]')
[[ "$before" == \[* ]] || before='[]'
debug "before=$before follow=$orig_follow cursor=$start_x,$start_y"

"$LAUNCHER" "$cmd" &
debug "launched pid=$!"

deadline=$((SECONDS + 6))
addr=""
while (( SECONDS < deadline )); do
  addr=$($HYPRCTL clients -j 2>/dev/null | $JQ -r --argjson old "$before" '
    .[]
    | select(.class == "org.omarchy.terminal" and .mapped == true and .hidden != true)
    | select((.size[0] // 0) > 200 and (.size[1] // 0) > 200)
    | select(.address as $a | ($old | index($a)) | not)
    | .address
  ' 2>/dev/null | tail -n1)
  [[ -n "$addr" ]] && break
  sleep 0.05
done

if [[ -z "$addr" ]]; then
  debug "no window found"
  exit 0
fi
debug "found addr=$addr"

win_center=$($HYPRCTL clients -j 2>/dev/null | $JQ -r --arg a "$addr" '
  .[] | select(.address == $a)
  | "\((.at[0] + .size[0] / 2) | floor) \((.at[1] + .size[1] / 2) | floor)"
')
read -r wx wy <<<"$win_center"
if [[ -n "$wx" && -n "$wy" ]]; then
  $HYPRCTL dispatch "hl.dsp.cursor.move({ x = $wx, y = $wy })" >/dev/null 2>&1 || true
  hide_cursor
  start_x=$wx
  start_y=$wy
fi

for _ in $(seq 1 20); do
  focus_window "$addr"
  current=$($HYPRCTL activewindow -j 2>/dev/null | $JQ -r '.address // empty')
  if [[ "$current" == "$addr" ]]; then
    debug "focused"
    break
  fi
  sleep 0.05
done

while window_still_mapped "$addr"; do
  if cursor_moved; then
    debug "cursor moved, restoring follow_mouse"
    break
  fi
  current=$($HYPRCTL activewindow -j 2>/dev/null | $JQ -r '.address // empty')
  if [[ "$current" != "$addr" ]]; then
    focus_window "$addr"
  fi
  sleep 0.12
done

debug "done"
exit 0
