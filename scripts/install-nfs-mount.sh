#!/usr/bin/env bash
set -euo pipefail
set +x +v

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$_script_dir/nfs-lib.sh"

nfs_install_automount "${1:-}" "${2:-/mnt/omaclone}"
