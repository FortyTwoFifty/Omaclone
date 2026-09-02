#!/usr/bin/env bash
set +x +v
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

export OMACLONE_SKIP_DISCOVER=1
exec python3 "$ROOT/scripts/run-helper.py" 65536 8 2 -- "$ROOT/scripts/omaclone" status --json
