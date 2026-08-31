#!/usr/bin/env bash
# Shared fixtures for omaclone tests. Source from a test script:
#   ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#   source "$ROOT/tests/helpers.sh"
#   omaclone_test_env
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

omaclone_test_env() {
  local home
  home=$(mktemp -d)
  OMACLONE_TEST_HOME="$home"
  export HOME="$home"
  export XDG_CONFIG_HOME="$home/.config"
  export XDG_DATA_HOME="$home/.local/share"
  export NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT:-$ROOT}"
  export NAS_BACKUP_USER_CONFIG_DIR="$home/.config/omaclone"
  export NAS_BACKUP_STATE_DIR="$home/.local/share/omaclone"
  export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"
  export OMACLONE_SKIP_SYSTEMD=1
  export OMACLONE_SKIP_DISCOVER=1
  export OMACLONE_SKIP_PREP=1
  export OMACLONE_SKIP_BOOTSTRAP=1
  unset NAS_BACKUP_LIB_LOADED OMACLONE_LOCATIONS_LOADED NAS_BACKUP_BACKEND_LOADED OMACLONE_DEPS_LOADED
  mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR" "$NAS_BACKUP_STATE_DIR" "$home/.local/bin"
  if declare -F omaclone_test_cleanup >/dev/null 2>&1; then
    :
  else
    omaclone_test_cleanup() { rm -rf "$OMACLONE_TEST_HOME"; }
    trap 'omaclone_test_cleanup' EXIT
  fi
}

omaclone_test_cfg() {
  python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set "$1" "$2"
}

omaclone_install_user_backend() {
  local kind="$1" name="$2" src="$3"
  mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/$kind"
  cp "$src" "$NAS_BACKUP_USER_CONFIG_DIR/backends/$kind/$name"
  chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/$kind/$name"
}

omaclone_install_dummy_secrets() {
  omaclone_install_user_backend secrets dummy "$NAS_BACKUP_ROOT/tests/backends/secrets/dummy"
}

omaclone_cli() {
  # Unattended: close stdin so password_load / gum never wait on a TTY.
  "$NAS_BACKUP_ROOT/scripts/omaclone" "$@" </dev/null
}

omaclone_last_result() {
  local field="${1:-status}"
  local loc="${2:-}"
  local path="$NAS_BACKUP_STATE_DIR/last-result.json"
  if [[ -n "$loc" && -f "$NAS_BACKUP_STATE_DIR/last-result-${loc}.json" ]]; then
    path="$NAS_BACKUP_STATE_DIR/last-result-${loc}.json"
  fi
  [[ -f "$path" ]] || fail "missing last-result at $path"
  jq -r --arg f "$field" '.[$f] // empty' "$path"
}
