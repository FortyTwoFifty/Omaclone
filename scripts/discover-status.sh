#!/usr/bin/env bash
set +x +v
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
unset OMACLONE_SKIP_DISCOVER
if command -v timeout >/dev/null 2>&1; then
  exec timeout -k 1 3 "$ROOT/scripts/omaclone" location list --json
fi
exec "$ROOT/scripts/omaclone" location list --json
