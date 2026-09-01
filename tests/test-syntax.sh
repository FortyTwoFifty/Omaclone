#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

shopt -s nullglob
files=(
  "$ROOT/scripts/omaclone"
  "$ROOT/scripts/"*.sh
  "$ROOT/scripts/cmd-"*.sh
  "$ROOT/scripts/restore"
  "$ROOT/backends/secrets/"*
  "$ROOT/backends/transport/"*
  "$ROOT/backends/notify/"*
  "$ROOT/tests/"*.sh
)
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.py) continue ;;
  esac
  head -n 1 "$f" | grep -q 'bash\|sh' || continue
  bash -n "$f" || fail "bash -n $f"
done

python3 -m py_compile "$ROOT"/scripts/*.py || fail "py_compile failed"

"$ROOT/scripts/omaclone" -h | grep -q verify || fail "usage missing verify"
"$ROOT/scripts/omaclone" -h | grep -q estimate || fail "usage missing estimate"
"$ROOT/scripts/omaclone" -h | grep -q copy || fail "usage missing copy"
[[ -f "$ROOT/scripts/cmd-setup.sh" ]] || fail "cmd-setup.sh missing"
[[ -f "$ROOT/scripts/cmd-clone.sh" ]] || fail "cmd-clone.sh missing"
[[ -f "$ROOT/scripts/cmd-restore.sh" ]] || fail "cmd-restore.sh missing"
[[ -f "$ROOT/scripts/cmd-status.sh" ]] || fail "cmd-status.sh missing"
[[ -f "$ROOT/ActionRow.qml" && -f "$ROOT/LocationRadio.qml" && -f "$ROOT/KeepPlan.qml" ]] \
  || fail "pane components missing"

echo OK
