#!/usr/bin/env bash
set +x +v
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

export OMACLONE_SKIP_DISCOVER=1

if command -v timeout >/dev/null 2>&1; then
  exec timeout -k 1 8 "$ROOT/scripts/omaclone" status --json
fi
exec "$ROOT/scripts/omaclone" status --json
