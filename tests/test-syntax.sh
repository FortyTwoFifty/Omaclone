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

# run.sh used to exec ./tests/foo.sh; a 100644 git mode then fails CI with
# "Permission denied" (rc=126). Keep the bits set so README's ./tests/*.sh works.
for t in "$ROOT"/tests/test-*.sh "$ROOT"/tests/run.sh "$ROOT"/tests/helpers.sh; do
  [[ -f "$t" ]] || continue
  [[ -x "$t" ]] || fail "$(basename "$t") is not executable (git update-index --chmod=+x tests/$(basename "$t"))"
done

python3 -m py_compile "$ROOT"/scripts/*.py "$ROOT"/tests/s3_create_bucket.py || fail "py_compile failed"

"$ROOT/scripts/omaclone" -h | grep -q verify || fail "usage missing verify"
"$ROOT/scripts/omaclone" -h | grep -q estimate || fail "usage missing estimate"
"$ROOT/scripts/omaclone" -h | grep -q copy || fail "usage missing copy"
"$ROOT/scripts/omaclone" -h | grep -q "location stats" || fail "usage missing location stats"
[[ -f "$ROOT/scripts/cmd-setup.sh" ]] || fail "cmd-setup.sh missing"
[[ -f "$ROOT/scripts/cmd-clone.sh" ]] || fail "cmd-clone.sh missing"
[[ -f "$ROOT/scripts/cmd-restore.sh" ]] || fail "cmd-restore.sh missing"
[[ -f "$ROOT/scripts/cmd-status.sh" ]] || fail "cmd-status.sh missing"
[[ -f "$ROOT/ActionRow.qml" && -f "$ROOT/LocationRadio.qml" && -f "$ROOT/KeepPlan.qml" ]] \
  || fail "pane components missing"

wf="$ROOT/.github/workflows/test.yml"
grep -q '^permissions:' "$wf" || fail "CI must declare top-level permissions"
grep -q 'contents: read' "$wf" || fail "CI must use contents: read"
grep -q 'actions/checkout@[0-9a-f]\{40\}' "$wf" || fail "CI must pin actions/checkout to a commit digest"
grep -q 'minio/minio@sha256:' "$wf" || fail "CI must pin the MinIO image digest"
grep -q 'sha256sum -c' "$wf" || fail "CI must verify gum checksums"
grep -q 'minio/minio:latest' "$wf" && fail "CI must not pull minio/minio:latest"
grep -q 'actions/checkout@v4' "$wf" && fail "CI must not use a floating checkout tag"

grep -q 'omaclone_privileged_clear_overrides' "$ROOT/scripts/lib.sh" \
  || fail "privileged handoff must unset inherited payload overrides"
if grep -q "exec(base64" "$ROOT/scripts/lib.sh" "$ROOT/scripts/transport-lib.sh"; then
  fail "must not interpolate helper payload into python -c"
fi
grep -q 'pass_fds' "$ROOT/scripts/privileged.py" || fail "mkfs must preserve the held device fd"
grep -q 'tf.next()' "$ROOT/scripts/privileged.py" || fail "etc tar must iterate members"
if grep -q 'getmembers()' "$ROOT/scripts/privileged.py"; then
  fail "etc tar must not materialize getmembers()"
fi
grep -q 'select.select' "$ROOT/scripts/run-helper.py" || fail "run-helper must cap pipes incrementally"
grep -q 'killpg' "$ROOT/scripts/run-helper.py" || fail "run-helper must reap the process group"

echo OK
