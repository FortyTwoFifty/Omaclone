#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
source "$ROOT/tests/helpers.sh"
omaclone_test_env
omaclone_install_dummy_secrets
unset NAS_BACKUP_LIB_LOADED NAS_BACKUP_BACKEND_LOADED
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/backend.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg secrets.keyring_offer declined
password_load </dev/null || fail "password_load failed"
[[ "$NAS_BACKUP_PWFILE" == /dev/fd/* ]] || fail "expected sealed /dev/fd path, got $NAS_BACKUP_PWFILE"
[[ -n "${NAS_BACKUP_PWFD:-}" ]] || fail "NAS_BACKUP_PWFD unset"
got=$(password_fd_contents)
[[ "$got" == "dummy-password-not-for-real-repos" ]] || fail "fd contents: $got"
for _f in /dev/shm/omaclone.pw.* /run/user/"$(id -u)"/omaclone.pw.*; do
  [[ -f "$_f" ]] || continue
  fail "named password file still present after seal: $_f"
done

mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/repo"
touch "$NAS_BACKUP_USER_CONFIG_DIR/repo/config"
omaclone_test_cfg restic.repo "$NAS_BACKUP_USER_CONFIG_DIR/repo"
omaclone_test_cfg transport.backend local

fake=$(mktemp -d)
trap 'rm -rf "$OMACLONE_TEST_HOME" "$fake"' EXIT
cat >"$fake/restic" <<'EOF'
#!/usr/bin/env bash
printf '%s ' "$@"
printf '\n'
exit 0
EOF
chmod +x "$fake/restic"
PATH="$fake:$PATH" restic_exec snapshots >"$fake/argv" || fail "restic_exec failed"
grep -q -- '--password-file /dev/fd/' "$fake/argv" || fail "restic argv should use /dev/fd: $(cat "$fake/argv")"
if grep -E -- '--password |^-p |/dev/shm/omaclone' "$fake/argv"; then
  fail "restic argv leaked a named password path: $(cat "$fake/argv")"
fi
password_cleanup

grep -n 'gum style --bold "$pw"' "$ROOT/scripts/cmd-setup.sh" && \
  fail "generated password must not be passed to gum as an argv word"
grep -nE 'restic --password |restic -p ' "$ROOT/scripts/lib.sh" "$ROOT/scripts/cmd-clone.sh" && \
  fail "must not pass restic --password / -p"

stale=$(mktemp -p /dev/shm omaclone.pw.XXXXXX)
printf '%s' 'stale-secret' >"$stale"
password_sweep_stale
[[ -e "$stale" ]] && fail "sweep left stale $stale"
echo OK
