#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/scripts/nfs-lib.sh"

assert_ok() {
  local name="$1"
  shift
  if ! "$@" >/dev/null; then
    fail "$name should succeed: $*"
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$name should fail: $*"
  fi
}

assert_ok "ipv4 uri" nfs_validate_uri "10.10.0.10:/mnt/pool/backups/omaclone"
assert_ok "hostname uri" nfs_validate_uri "truenas.local:/mnt/pool/backups"
assert_ok "trimmed uri" nfs_validate_uri "  nas:/export  "
assert_ok "root export" nfs_validate_uri "nas:/"
assert_ok "ipv6 uri" nfs_validate_uri "[2001:db8::1]:/export"

nfs_parse_uri "10.10.0.10:/mnt/pool/backups" || fail "parse valid uri"
[[ "$NFS_HOST" == "10.10.0.10" ]] || fail "host: $NFS_HOST"
[[ "$NFS_EXPORT" == "/mnt/pool/backups" ]] || fail "export: $NFS_EXPORT"

nfs_parse_uri "nas:/export/" || fail "parse trailing slash"
[[ "$NFS_EXPORT" == "/export" ]] || fail "normalized export: $NFS_EXPORT"

assert_fail "empty uri" nfs_validate_uri ""
assert_fail "host only" nfs_validate_uri "10.10.0.10"
assert_fail "relative export" nfs_validate_uri "nas:export"
assert_fail "smb path" nfs_validate_uri "//10.10.0.10/backups"
assert_fail "url" nfs_validate_uri "nfs://10.10.0.10/export"
assert_fail "missing host" nfs_validate_uri ":/export"
assert_fail "space in uri" nfs_validate_uri "nas host:/export"

assert_ok "default mp" nfs_validate_mountpoint "/mnt/omaclone"
assert_ok "trailing slash mp" nfs_validate_mountpoint "/mnt/omaclone/"
assert_ok "nested mp" nfs_validate_mountpoint "/mnt/data/omaclone"
assert_fail "empty mp" nfs_validate_mountpoint ""
assert_fail "relative mp" nfs_validate_mountpoint "mnt/omaclone"
assert_fail "root mp" nfs_validate_mountpoint "/"
assert_fail "mnt mp" nfs_validate_mountpoint "/mnt"
assert_fail "home mp" nfs_validate_mountpoint "/home"
assert_fail "tmp mp" nfs_validate_mountpoint "/tmp"
assert_fail "space mp" nfs_validate_mountpoint "/mnt/oma clone"
assert_fail "dotdot mp" nfs_validate_mountpoint "/mnt/../../etc"
assert_fail "dotdot boot" nfs_validate_mountpoint "/mnt/foo/../../boot"
assert_fail "comma uri" nfs_validate_uri "nas:/export,suid"

assert_ok "repo on share" nfs_validate_repo "/mnt/omaclone/repo" "/mnt/omaclone"
assert_ok "repo is share" nfs_validate_repo "/mnt/omaclone" "/mnt/omaclone"
assert_fail "empty repo" nfs_validate_repo "" "/mnt/omaclone"
assert_fail "relative repo" nfs_validate_repo "repo" "/mnt/omaclone"
assert_fail "repo off share" nfs_validate_repo "/var/lib/restic" "/mnt/omaclone"

nfs_host_resolves "127.0.0.1" || fail "loopback should count as resolved"
nfs_host_resolves "this-host-does-not-exist.invalid" && fail "bogus host should not resolve"

if nfs_check_available "this-host-does-not-exist.invalid:/mnt/backups" 2>/dev/null; then
  fail "unresolvable NFS host should not be reported available"
fi

_orig_nfs_findmnt_nfs_source=$(declare -f nfs_findmnt_nfs_source)
_orig_nfs_findmnt_first_source=$(declare -f nfs_findmnt_first_source)
_orig_nfs_findmnt_covers=$(declare -f nfs_findmnt_covers)
_orig_nfs_unit_what=$(declare -f nfs_unit_what)
restore_nfs_findmnt_stubs() {
  eval "$_orig_nfs_findmnt_nfs_source"
  eval "$_orig_nfs_findmnt_first_source"
  eval "$_orig_nfs_findmnt_covers"
  eval "$_orig_nfs_unit_what"
}

nfs_findmnt_nfs_source() { printf '%s\n' "10.10.0.10:/mnt/pool/omaclone"; }
nfs_findmnt_first_source() { printf '%s\n' "systemd-1"; }
nfs_findmnt_covers() { return 0; }
nfs_unit_what() { printf '%s\n' ""; }
assert_ok "stacked nfs already mounted" nfs_already_mounted "10.10.0.10:/mnt/pool/omaclone" /mnt/omaclone
assert_fail "stacked nfs not busy" nfs_mountpoint_busy "10.10.0.10:/mnt/pool/omaclone" /mnt/omaclone
assert_fail "stacked different export not already mounted" nfs_already_mounted "10.10.0.10:/mnt/other" /mnt/omaclone
assert_ok "stacked different export is busy" nfs_mountpoint_busy "10.10.0.10:/mnt/other" /mnt/omaclone
[[ "$(nfs_mountpoint_source_label /mnt/omaclone)" == "10.10.0.10:/mnt/pool/omaclone" ]] \
  || fail "source label should prefer nfs row, got $(nfs_mountpoint_source_label /mnt/omaclone)"

nfs_findmnt_nfs_source() { printf '%s\n' ""; }
nfs_findmnt_first_source() { printf '%s\n' "systemd-1"; }
nfs_findmnt_covers() { return 0; }
nfs_unit_what() { printf '%s\n' "10.10.0.10:/mnt/pool/omaclone"; }
assert_ok "idle autofs already mounted" nfs_already_mounted "10.10.0.10:/mnt/pool/omaclone" /mnt/omaclone
assert_fail "idle autofs not busy" nfs_mountpoint_busy "10.10.0.10:/mnt/pool/omaclone" /mnt/omaclone

nfs_unit_what() { printf '%s\n' "10.10.0.10:/mnt/other"; }
assert_fail "idle autofs other unit not ours" nfs_already_mounted "10.10.0.10:/mnt/pool/omaclone" /mnt/omaclone
assert_ok "idle autofs other unit is busy" nfs_mountpoint_busy "10.10.0.10:/mnt/pool/omaclone" /mnt/omaclone

nfs_findmnt_nfs_source() { printf '%s\n' ""; }
nfs_findmnt_first_source() { printf '%s\n' ""; }
nfs_findmnt_covers() { return 1; }
nfs_unit_what() { printf '%s\n' "10.10.0.10:/mnt/pool/omaclone"; }
assert_fail "unmounted leftover unit not already mounted" nfs_already_mounted "10.10.0.10:/mnt/pool/omaclone" /mnt/omaclone
assert_fail "unmounted leftover unit not busy" nfs_mountpoint_busy "10.10.0.10:/mnt/pool/omaclone" /mnt/omaclone

restore_nfs_findmnt_stubs

sudo_log=$(mktemp)
install_out=$(mktemp)
tmpbin=$(mktemp -d)
trap 'rm -f "$sudo_log" "$install_out"; rm -rf "$tmpbin"' EXIT
cat >"$tmpbin/sudo" <<EOF
#!/bin/sh
echo SUDO_CALLED "\$*" >>"$sudo_log"
exit 1
EOF
chmod +x "$tmpbin/sudo"

set +e
PATH="$tmpbin:$PATH" "$ROOT/scripts/install-nfs-mount.sh" "not-an-nfs-uri" /mnt/omaclone >"$install_out" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "install-nfs-mount.sh should reject a bad URI"
if [[ -s "$sudo_log" ]]; then
  fail "install-nfs-mount.sh called sudo before validating URI: $(cat "$sudo_log")"
fi

set +e
PATH="$tmpbin:$PATH" "$ROOT/scripts/install-nfs-mount.sh" "10.10.0.10:/export" /mnt >"$install_out" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "install-nfs-mount.sh should reject mountpoint /mnt"
if [[ -s "$sudo_log" ]]; then
  fail "install-nfs-mount.sh called sudo for a forbidden mountpoint: $(cat "$sudo_log")"
fi

set +e
PATH="$tmpbin:$PATH" "$ROOT/scripts/install-nfs-mount.sh" "this-host-does-not-exist.invalid:/mnt/backups" /mnt/omaclone >"$install_out" 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "install-nfs-mount.sh should reject an unresolvable host"
if [[ -s "$sudo_log" ]]; then
  fail "install-nfs-mount.sh called sudo for an unresolvable host: $(cat "$sudo_log")"
fi

grep -q 'fg,_netdev,nosuid,nodev,noexec' "$ROOT/scripts/nfs-lib.sh" \
  || fail "nfs probe mount must include nosuid,nodev,noexec"

echo "OK"
