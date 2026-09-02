#!/usr/bin/env bash
set +x +v
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
unset OMACLONE_SKIP_DISCOVER
exec python3 "$ROOT/scripts/run-helper.py" 65536 3 2 -- "$ROOT/scripts/omaclone" location list --json
