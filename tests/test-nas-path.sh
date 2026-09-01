#!/usr/bin/env bash
# Hermetic coverage for the NAS destination path (nfs/cifs/sftp/local).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env

omaclone_install_dummy_secrets
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/backend.sh"
source "$ROOT/scripts/nfs-lib.sh"

# --- NFS unit template vs interactive mount ---
[[ "$(nfs_mount_options)" == *nconnect=8* ]] || fail "nfs_mount_options must include nconnect=8"
[[ "$(nfs_mount_options)" == *nosuid,nodev,noexec* ]] || fail "nfs_mount_options must include nosuid,nodev,noexec"
unitdir=$(mktemp -d)
nfs_write_unit_files "10.10.0.10:/mnt/pool/backups" /mnt/omaclone "$unitdir"
grep -q 'nconnect=8' "$unitdir"/*.mount || fail "generated mount unit missing nconnect=8"
grep -q 'nosuid,nodev,noexec' "$unitdir"/*.mount || fail "generated mount unit missing nosuid,nodev,noexec"
grep -q 'TimeoutIdleSec=600' "$unitdir"/*.automount || fail "nfs automount should idle-unmount"
rm -rf "$unitdir"

# --- NFS transport contract ---
[[ "$(nas_backup_backend_run transport nfs id)" == nfs ]] || fail "nfs id"
nas_backup_backend_run transport nfs describe | grep -qi NFS || fail "nfs describe"
nas_backup_transport_has nfs mount || fail "nfs should have mount capability"
nas_backup_transport_has nfs remote && fail "nfs should not be remote"
nas_backup_backend_available transport nfs || fail "nfs should be available when nfs-utils is installed"

# --- NFS ready: missing mountpoint is not ready ---
omaclone_test_cfg transport.backend nfs
omaclone_test_cfg transport.uri "10.10.0.10:/mnt/pool/backups"
omaclone_test_cfg transport.mountpoint "/mnt/omaclone-nas-path-missing-$$"
omaclone_test_cfg restic.repo "/mnt/omaclone-nas-path-missing-$$/omaclone/repo"
if nas_backup_backend_run transport nfs ready >/dev/null 2>&1; then
  fail "nfs ready should fail when the mountpoint is not mounted"
fi

# --- NFS ready: requires nfs/nfs4, not autofs ---
mp=$(mktemp -d)
repo_parent="$mp/omaclone"
mkdir -p "$repo_parent"
omaclone_test_cfg transport.mountpoint "$mp"
omaclone_test_cfg restic.repo "$repo_parent/repo"
tmpbin=$(mktemp -d)
cat >"$tmpbin/findmnt" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    nfs,nfs4|nfs|nfs4) exit 0 ;;
  esac
done
exit 1
EOF
chmod +x "$tmpbin/findmnt"
PATH="$tmpbin:$PATH" nas_backup_backend_run transport nfs ready >/dev/null 2>&1 \
  || fail "nfs ready should succeed when findmnt -t nfs,nfs4 succeeds"

cat >"$tmpbin/findmnt" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    nfs,nfs4|nfs|nfs4) exit 1 ;;
  esac
done
echo autofs
exit 0
EOF
chmod +x "$tmpbin/findmnt"
if PATH="$tmpbin:$PATH" nas_backup_backend_run transport nfs ready >/dev/null 2>&1; then
  fail "nfs ready must not treat autofs as a live NFS share"
fi
rm -rf "$tmpbin" "$mp"

# --- Cron skip when NFS is not mounted (fake sudo, no real mount) ---
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg secrets.keyring_offer declined
omaclone_test_cfg destination.profile nas
omaclone_test_cfg destination.vendor truenas
omaclone_test_cfg retention.preset last-5
omaclone_test_cfg locations.ids nas
omaclone_test_cfg locations.active nas
omaclone_test_cfg locations.nas.backend nfs
omaclone_test_cfg locations.nas.uri "127.0.0.1:/no-such-omaclone-export"
omaclone_test_cfg locations.nas.mountpoint "/mnt/omaclone-nas-path-missing-$$"
omaclone_test_cfg locations.nas.repo "/mnt/omaclone-nas-path-missing-$$/omaclone/repo"
omaclone_test_cfg locations.nas.label NAS
omaclone_test_cfg locations.nas.profile nas
omaclone_test_cfg locations.nas.schedule on
omaclone_test_cfg transport.backend nfs
omaclone_test_cfg transport.uri "127.0.0.1:/no-such-omaclone-export"
omaclone_test_cfg transport.mountpoint "/mnt/omaclone-nas-path-missing-$$"
omaclone_test_cfg restic.repo "/mnt/omaclone-nas-path-missing-$$/omaclone/repo"

sudo_log=$(mktemp)
tmpbin=$(mktemp -d)
cat >"$tmpbin/sudo" <<EOF
#!/bin/sh
echo SUDO "\$*" >>"$sudo_log"
exit 1
EOF
chmod +x "$tmpbin/sudo"

set +e
PATH="$tmpbin:$PATH" omaclone_cli clone --cron >/tmp/omaclone-nas-cron.$$ 2>&1
rc=$?
set -e
(( rc == 0 )) || fail "unmounted nfs --cron should exit 0, got $rc: $(cat /tmp/omaclone-nas-cron.$$)"
[[ "$(omaclone_last_result status)" == skip ]] || fail "unmounted nfs: expected skip, got $(omaclone_last_result status)"
printf '%s\n' "$(omaclone_last_result message)" | grep -qi "not mounted" \
  || fail "unmounted nfs: expected not mounted, got $(omaclone_last_result message)"
sev=$(omaclone_cli status --json | jq -r '.severity')
[[ "$sev" == warning ]] || fail "unmounted nfs skip must be warning, severity=$sev"
rm -f /tmp/omaclone-nas-cron.$$ "$sudo_log"
rm -rf "$tmpbin"

# --- Location JSON: disconnected nfs stays listed ---
json=$(omaclone_cli location list --json)
echo "$json" | jq -e '.[] | select(.id=="nas")' >/dev/null || fail "nas missing from location json"
conn=$(echo "$json" | jq -r '.[] | select(.id=="nas") | .connected')
[[ "$conn" == false ]] || fail "missing nfs mount should be connected=false, got $conn"
src=$(echo "$json" | jq -r '.[] | select(.id=="nas") | .source')
[[ "$src" == config ]] || fail "nas source should be config, got $src"

# --- local transport: plain directory outside /mnt is ready ---
local_root=$(mktemp -d)
omaclone_test_cfg transport.backend local
omaclone_test_cfg transport.mountpoint "$local_root"
omaclone_test_cfg restic.repo "$local_root/omaclone/repo"
if nas_backup_backend_run transport local ready >/dev/null 2>&1; then
  fail "local ready should fail when dirname(repo) does not exist"
fi
mkdir -p "$local_root/omaclone"
nas_backup_backend_run transport local ready \
  || fail "local ready succeeds once dirname(repo) exists"
[[ "$(nas_backup_backend_run transport local id)" == local ]] || fail "local id"
nas_backup_transport_has local mount || fail "local should have mount capability"
rm -rf "$local_root"

# --- Bootstrap kit has no secrets ---
kit=$(mktemp -d)
omaclone_test_cfg transport.backend nfs
omaclone_test_cfg transport.uri "10.10.0.10:/mnt/plumbus/Omaclone"
omaclone_test_cfg transport.mountpoint "/mnt/Omaclone-NAS"
omaclone_test_cfg restic.repo "/mnt/Omaclone-NAS/omaclone/repo"
omaclone_test_cfg secrets.backend dummy
python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" set secrets.item "Omaclone Password"
python3 "$NAS_BACKUP_ROOT/scripts/bootstrap_copy.py" "$ROOT" "$kit" "$NAS_BACKUP_CONFIG"
[[ -x "$kit/restore" ]] || fail "kit restore not executable"
[[ -f "$kit/SHA256SUMS" ]] || fail "kit missing SHA256SUMS"
[[ -f "$kit/config.toml" ]] || fail "kit missing config.toml"
[[ -f "$kit/.omaclone-bootstrap" ]] || fail "kit missing bootstrap marker"
if grep -qiE 'password\s*=' "$kit/config.toml"; then
  fail "kit config.toml leaked a password key"
fi
grep -q 'backend = "nfs"' "$kit/config.toml" || fail "kit should keep transport.backend"
grep -q '10.10.0.10:/mnt/plumbus/Omaclone' "$kit/config.toml" || fail "kit should keep nfs uri"
python3 "$ROOT/scripts/bootstrap_copy.py" --verify "$kit/SHA256SUMS" "$kit/omaclone" \
  || fail "kit SHA256SUMS did not verify"
rm -rf "$kit"

# --- CIFS: stub mount, credentials 600 on tmpfs, shredded ---
omaclone_test_file_keyring
omaclone_test_put_transport_secret smb-password "smb-test-password-not-real"
cifs_mp=$(mktemp -d)
omaclone_test_cfg transport.backend cifs
omaclone_test_cfg transport.uri "//nas.example/share"
omaclone_test_cfg transport.mountpoint "$cifs_mp"
omaclone_test_cfg transport.username testhost
omaclone_test_cfg restic.repo "$cifs_mp/omaclone/repo"
cred_copy=$(mktemp)
sudo_log=$(mktemp)
tmpbin=$(mktemp -d)
cat >"$tmpbin/sudo" <<EOF
#!/bin/sh
echo SUDO "\$*" >>"$sudo_log"
# sudo_noninteractive passes -n when stdin is not a tty.
while [ "\$1" = -n ] || [ "\$1" = --non-interactive ]; do
  shift
done
if [ "\$1" = mkdir ]; then
  shift
  mkdir "\$@"
  exit \$?
fi
if [ "\$1" = mount ]; then
  cred=""
  for arg in "\$@"; do
    case "\$arg" in
      credentials=*) cred="\${arg#credentials=}" ;;
    esac
    opt="\$arg"
    oldifs=\$IFS
    IFS=,
    for part in \$opt; do
      case "\$part" in
        credentials=*) cred="\${part#credentials=}" ;;
      esac
    done
    IFS=\$oldifs
  done
  if [ -z "\$cred" ] || [ ! -f "\$cred" ]; then
    echo "cifs stub: missing credentials file" >&2
    exit 1
  fi
  mode=\$(stat -c '%a' "\$cred")
  echo "\$mode" >"$cred_copy.mode"
  cp "\$cred" "$cred_copy"
  exit 0
fi
exit 1
EOF
chmod +x "$tmpbin/sudo"
# mount.cifs is not invoked directly; sudo mount -t cifs is.
if ! PATH="$tmpbin:$PATH" nas_backup_backend_run transport cifs mount >/tmp/omaclone-cifs-mount.$$ 2>&1; then
  fail "cifs mount with stub sudo should succeed: $(cat /tmp/omaclone-cifs-mount.$$)"
fi
[[ -s "$cred_copy" ]] || fail "cifs stub did not capture credentials file"
grep -q '^username=testhost$' "$cred_copy" || fail "cifs cred missing username: $(cat "$cred_copy")"
grep -q '^password=smb-test-password-not-real$' "$cred_copy" || fail "cifs cred missing password"
mode=$(cat "$cred_copy.mode")
[[ "$mode" == 600 ]] || fail "cifs cred mode should be 600, got $mode"
# Original tmpfs cred should be gone
if grep -o 'omaclone.smb.[A-Za-z0-9]*' "$sudo_log" >/dev/null; then
  :
fi
leftover=$(find /dev/shm /run/user/"$(id -u)" -maxdepth 1 -name 'omaclone.smb.*' 2>/dev/null || true)
[[ -z "$leftover" ]] || fail "cifs credential file not shredded: $leftover"
grep -q 'vers=3.0' "$ROOT/backends/transport/cifs" || fail "cifs should request SMB3"
rm -f /tmp/omaclone-cifs-mount.$$ "$cred_copy" "$cred_copy.mode" "$sudo_log"
rm -rf "$tmpbin" "$cifs_mp"

# --- SFTP is a remote NAS transport (copy refuses it) ---
nas_backup_transport_has sftp remote || fail "sftp should be remote"
nas_backup_transport_has sftp mount && fail "sftp should not be mount"
grep -q 'StrictHostKeyChecking=yes' "$ROOT/backends/transport/sftp" \
  || fail "sftp must force StrictHostKeyChecking=yes"

# --- Recovery card for NFS mentions share restore, not S3 plugin-only ---
omaclone_test_cfg transport.backend nfs
omaclone_test_cfg destination.profile nas
omaclone_test_cfg transport.uri "10.10.0.10:/mnt/plumbus/Omaclone"
omaclone_test_cfg transport.mountpoint "/mnt/Omaclone-NAS"
omaclone_test_cfg restic.repo "/mnt/Omaclone-NAS/omaclone/repo"
card=$(write_recovery_card)
grep -qi "NAS" "$card" || grep -q "/mnt/Omaclone-NAS" "$card" \
  || fail "nfs recovery card should mention the share: $(cat "$card")"
grep -q "/path/to/clone/restore" "$card" || grep -qi "restore" "$card" \
  || fail "nfs recovery card should mention restore"
if grep -qiE 'password\s*[:=]' "$card"; then
  fail "recovery card leaked a password"
fi

# --- location --json is accepted without subcommand ---
json=$(omaclone_cli location --json)
echo "$json" | jq -e 'type=="array"' >/dev/null || fail "location --json should print an array: $json"

# --- kit restore must not assume NFS when transport is empty ---
if grep -E 'nfs\|""' "$ROOT/scripts/restore" >/dev/null; then
  fail "kit restore must not install nfs-utils when transport.backend is empty"
fi

# --- local: unmounted /mnt path is not ready ---
omaclone_test_cfg transport.backend local
omaclone_test_cfg transport.mountpoint "/mnt/omaclone-local-not-mounted-$$"
omaclone_test_cfg restic.repo "/mnt/omaclone-local-not-mounted-$$/omaclone/repo"
if nas_backup_backend_run transport local ready >/dev/null 2>&1; then
  fail "local ready should fail for an unmounted /mnt path"
fi
plain=$(mktemp -d)
omaclone_test_cfg transport.mountpoint "$plain"
omaclone_test_cfg restic.repo "$plain/omaclone/repo"
mkdir -p "$plain/omaclone"
nas_backup_backend_run transport local ready \
  || fail "local ready should allow a plain directory that is not under /mnt"
rm -rf "$plain"

# --- cold disk default label is USB ---
source "$ROOT/scripts/locations.sh"
[[ "$(location_default_label disk disk cold)" == USB ]] || fail "cold disk default label should be USB"
[[ "$(location_default_label disk disk hot)" == "Extra disk" ]] || fail "hot disk default label should be Extra disk"

# --- orphan location sections are dropped ---
omaclone_test_cfg locations.ids nas
omaclone_test_cfg locations.nas.backend nfs
omaclone_test_cfg locations.usb-2.backend disk
omaclone_test_cfg locations.usb-2.uri "10.10.0.10:/mnt/plumbus/Omaclone"
location_ids_compact
got=$(python3 "$ROOT/scripts/config.py" "$NAS_BACKUP_CONFIG" get locations.usb-2.backend)
[[ -z "$got" ]] || fail "orphan locations.usb-2 should be dropped, got $got"

# --- sftp without a reachable host is offline ---
omaclone_test_cfg locations.ids sftp-nas
omaclone_test_cfg locations.active sftp-nas
omaclone_test_cfg locations.sftp-nas.backend sftp
omaclone_test_cfg locations.sftp-nas.host ""
omaclone_test_cfg locations.sftp-nas.repo "sftp:nobody@127.0.0.1:omaclone/repo"
omaclone_test_cfg locations.sftp-nas.label NAS
json=$(omaclone_cli location --json)
conn=$(echo "$json" | jq -r '.[] | select(.id=="sftp-nas") | .connected')
[[ "$conn" == false ]] || fail "sftp with empty host should be offline, got $conn"

echo OK
