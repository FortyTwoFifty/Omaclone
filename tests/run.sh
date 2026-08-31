#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

tests=(
  tests/test-backend-contract.sh
  tests/test-transport-contract.sh
  tests/test-migration.sh
  tests/test-retention.sh
  tests/test-locations.sh
  tests/test-nfs.sh
  tests/test-disk.sh
  tests/test-deps.sh
  tests/test-discover.sh
  tests/test-forget.sh
  tests/test-secrets-retry.sh
  tests/test-keyring-store.sh
  tests/test-install.sh
  tests/test-setup.sh
  tests/test-units.sh
  tests/test-cron-skip.sh
  tests/test-restic-roundtrip.sh
)

failed=0
passed=0
skipped=0

run_one() {
  local name="$1" start now rc
  printf '==> %s\n' "$name"
  start=$(date +%s)
  set +e
  if [[ "$name" == *.js ]]; then
    node "./$name"
    rc=$?
  else
    "./$name"
    rc=$?
  fi
  set -e
  now=$(date +%s)
  if (( rc == 0 )); then
    printf 'OK  %s (%ss)\n' "$name" "$((now - start))"
    passed=$((passed + 1))
  else
    printf 'FAIL %s (%ss, rc=%s)\n' "$name" "$((now - start))" "$rc"
    failed=$((failed + 1))
  fi
}

for t in "${tests[@]}"; do
  run_one "$t"
done

if command -v node >/dev/null 2>&1; then
  run_one tests/test-model.js
else
  printf 'SKIP tests/test-model.js (no node)\n'
  skipped=$((skipped + 1))
fi

if command -v omarchy >/dev/null 2>&1; then
  printf '==> omarchy plugin validate .\n'
  start=$(date +%s)
  set +e
  omarchy plugin validate .
  rc=$?
  set -e
  now=$(date +%s)
  if (( rc == 0 )); then
    printf 'OK  omarchy plugin validate (%ss)\n' "$((now - start))"
    passed=$((passed + 1))
  else
    printf 'FAIL omarchy plugin validate (rc=%s)\n' "$rc"
    failed=$((failed + 1))
  fi
else
  printf 'SKIP omarchy plugin validate (omarchy not on PATH)\n'
  skipped=$((skipped + 1))
fi

echo
printf 'passed=%s failed=%s skipped=%s\n' "$passed" "$failed" "$skipped"
(( failed == 0 ))
