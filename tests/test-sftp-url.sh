#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'StrictHostKeyChecking=yes' "$ROOT/backends/transport/sftp" \
  || fail "sftp should force StrictHostKeyChecking=yes"
grep -q 'remote_path "omaclone"' "$ROOT/backends/transport/sftp" \
  || fail "sftp default remote path should be omaclone, not /backup/omarchy"
if grep -q '/backup/omarchy' "$ROOT/backends/transport/sftp"; then
  fail "sftp still mentions leftover /backup/omarchy"
fi

# restic URL shape for port 22 vs non-22
export NAS_BACKUP_ROOT="$ROOT"
NAS_BACKUP_CONFIG=$(mktemp)
trap 'rm -f "$NAS_BACKUP_CONFIG"' EXIT
cat >"$NAS_BACKUP_CONFIG" <<'TOML'
[transport]
backend = "sftp"
username = "bp"
host = "nas.example"
port = "22"
remote_path = "omaclone"
TOML
source "$ROOT/scripts/transport-lib.sh"
# shellcheck source=/dev/null
got=$(bash -c '
  source "$NAS_BACKUP_ROOT/scripts/transport-lib.sh"
  source "$NAS_BACKUP_ROOT/backends/transport/sftp"
' 2>/dev/null || true)

url=$(NAS_BACKUP_ROOT="$ROOT" NAS_BACKUP_CONFIG="$NAS_BACKUP_CONFIG" bash -c '
  source "$NAS_BACKUP_ROOT/scripts/transport-lib.sh"
  cfg() { python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get "$1" "${2:-}"; }
  user=$(cfg transport.username)
  host=$(cfg transport.host)
  port=$(cfg transport.port 22)
  remote=$(cfg transport.remote_path)
  remote="${remote%/}/repo"
  printf "sftp:%s@%s:%s\n" "$user" "$host" "$remote"
')
[[ "$url" == "sftp:bp@nas.example:omaclone/repo" ]] || fail "port 22 url: $url"

python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set transport.port 2222
url=$(NAS_BACKUP_ROOT="$ROOT" NAS_BACKUP_CONFIG="$NAS_BACKUP_CONFIG" bash -c '
  source "$NAS_BACKUP_ROOT/scripts/transport-lib.sh"
  cfg() { python3 "$NAS_BACKUP_ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get "$1" "${2:-}"; }
  user=$(cfg transport.username)
  host=$(cfg transport.host)
  port=$(cfg transport.port 22)
  remote=$(cfg transport.remote_path)
  remote="${remote%/}/repo"
  if [[ "$remote" == /* ]]; then
    printf "sftp://%s@%s:%s/%s\n" "$user" "$host" "$port" "$remote"
  else
    printf "sftp://%s@%s:%s/%s\n" "$user" "$host" "$port" "$remote"
  fi
')
[[ "$url" == "sftp://bp@nas.example:2222/omaclone/repo" ]] || fail "port 2222 url: $url"

echo OK
