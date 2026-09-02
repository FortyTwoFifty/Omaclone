#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
NAS_BACKUP_USER_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR"' EXIT
export NAS_BACKUP_USER_CONFIG_DIR
export NAS_BACKUP_STATE_DIR="$NAS_BACKUP_USER_CONFIG_DIR/state"
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"
mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets"
cp "$ROOT/tests/backends/secrets/dummy" "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/dummy"
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/dummy"
unset NAS_BACKUP_LIB_LOADED NAS_BACKUP_BACKEND_LOADED
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/backend.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

config_set secrets.backend dummy
config_set secrets.keyring_offer declined
password_load </dev/null || fail "test 1: password_load failed with dummy backend"
[[ -n "${NAS_BACKUP_PWFD:-}" ]] || fail "test 1: NAS_BACKUP_PWFD unset"
contents=$(password_fd_contents)
[[ "$contents" == "dummy-password-not-for-real-repos" ]] \
  || fail "test 1: pwfile contents mismatch: $contents"
password_cleanup

cat >"$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/failing" <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
id() { echo failing; }
describe() { echo failing; }
available() { exit 0; }
setup() { exit 0; }
get() { echo "This operation requires an authenticated client" >&2; exit 1; }
put() { exit 2; }
unlock() { exit 2; }
case "$cmd" in
id) id ;;
describe) describe ;;
available) available ;;
setup) setup ;;
get) get ;;
unlock) unlock ;;
put) put ;;
*) exit 2 ;;
esac
BACKEND
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/failing"

config_set secrets.backend failing
set +e
if out=$(password_load </dev/null 2>&1); then
  fail "test 2: password_load should have failed (rc=0)"
fi
set -e
echo "$out" | grep -qF "secret backend 'failing' failed to provide a password" \
  || fail "test 2: missing die string in output: $out"

got=$(secrets_error_kind pass-cli "This operation requires an authenticated client")
[[ "$got" == "need_login" ]] || fail "test 3: got=$got expected=need_login"

got=$(secrets_error_kind 1password "you are not currently signed in")
[[ "$got" == "need_login" ]] || fail "test 4: got=$got expected=need_login"

got=$(secrets_error_kind pass-cli "item not found in vault")
[[ "$got" == "not_found" ]] || fail "test 5: got=$got expected=not_found"

got=$(secrets_error_kind x "")
[[ "$got" == "empty" ]] || fail "test 6: got=$got expected=empty"

config_set transport.backend nfs
config_set restic.repo "$NAS_BACKUP_USER_CONFIG_DIR/no-repo"
config_set secrets.backend dummy
setup_is_unfinished && true || fail "test 7: should be unfinished (no repo/config)"

mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/no-repo"
touch "$NAS_BACKUP_USER_CONFIG_DIR/no-repo/config"
setup_is_unfinished && true || fail "test 8a: repo without locations.ids should still be unfinished"
config_set locations.ids "nas"
if setup_is_unfinished; then
  fail "test 8b: should NOT be unfinished after repo + location id"
fi
rm -f "$NAS_BACKUP_USER_CONFIG_DIR/no-repo/config"
config_set transport.backend nfs
config_set transport.mountpoint "/mnt/omaclone-not-mounted-$$"
config_set restic.repo "/mnt/omaclone-not-mounted-$$/omaclone/repo"
config_set locations.ids "nas"
if setup_is_unfinished; then
  fail "test 8c: offline NAS with a saved location must not look unfinished"
fi
config_set transport.backend disk
config_set transport.uuid "NO-SUCH-USB-UUID"
config_set transport.mode cold
config_set restic.repo "/mnt/missing-usb/omaclone/repo"
config_set locations.ids "usb"
if setup_is_unfinished; then
  fail "test 8d: unplugged USB with a saved location must not look unfinished"
fi

rm -f "$NAS_BACKUP_USER_CONFIG_DIR/no-repo/config"
config_set locations.ids ""
setup_is_unfinished && true || fail "test 9: should be unfinished again after removing config"

secrets_has_unlock dummy || fail "test 10a: dummy should have unlock"
secrets_has_unlock failing || fail "test 10b: failing should have unlock"
if secrets_has_unlock prompt; then
  fail "test 10c: prompt should NOT have unlock"
fi

bash -n "$ROOT/backends/secrets/pass-cli" || fail "test 11a: pass-cli syntax error"
bash -n "$ROOT/backends/secrets/1password" || fail "test 11b: 1password syntax error"

config_set secrets.backend dummy
if grep -q dummy-password "$NAS_BACKUP_CONFIG"; then
  fail "test 12: password leaked into config"
fi

set +e
deferred_out=$(password_deferred_note 2>&1) || true
set -e
echo "$deferred_out" | grep -qF "omaclone setup" \
  || fail "test 13: deferred note missing 'omaclone setup': $deferred_out"

config_set transport.backend s3
config_set restic.repo "s3:https://example.invalid/bucket"
config_set secrets.backend dummy
config_set restic.initialized ""
setup_is_unfinished && true || fail "test 14a: s3 without init/last-result should be unfinished"
mkdir -p "$NAS_BACKUP_STATE_DIR"
printf '%s\n' '{"status":"ok","message":"backup completed","unix":1}' >"$NAS_BACKUP_STATE_DIR/last-result.json"
setup_is_unfinished && true || fail "test 14b: last-result ok without locations.ids should still be unfinished"
config_set locations.ids "cloud"
setup_is_unfinished && true || fail "test 14c: s3 last-result ok must not count as initialized"
config_set restic.initialized 1
if setup_is_unfinished; then
  fail "test 14d: s3 with restic.initialized=1 and a location should be finished"
fi

secrets_notice_is_update "New update available: v1 -> v2 (run \"pass-cli update\")" \
  || fail "test 15a: should match 'new update available'"
secrets_notice_is_update "UPDATE AVAILABLE for pass-cli" \
  || fail "test 15b: case-insensitive match"
secrets_notice_is_update "A new version of op is ready" \
  || fail "test 15c: should match 'a new version'"
secrets_notice_is_update "run \"op\" update now" \
  || fail "test 15d: should match op update notice"
secrets_notice_is_update "failed to update session token" \
  && fail "test 15e: generic 'update' should NOT match"
secrets_notice_is_update "" \
  && fail "test 15f: empty text should not match"
secrets_notice_is_update "this operation failed to update the session" \
  && fail "test 15g: 'operation' plus 'update' should NOT match"

if ! secrets_has_update pass-cli; then
  fail "test 16a: pass-cli should have update verb"
fi
if ! secrets_has_update 1password; then
  fail "test 16b: 1password should have update verb"
fi
if secrets_has_update prompt; then
  fail "test 16c: prompt should NOT have update verb"
fi
if secrets_has_update example; then
  fail "test 16d: example stub should NOT have update verb"
fi

mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets"
cat >"$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/notice_backend" <<'NBEOF'
#!/usr/bin/env bash
set +x +v
cmd="${1:-}"
id() { printf '%s\n' notice_backend; }
describe() { printf '%s\n' "Notice backend"; }
available() { exit 0; }
setup() { exit 0; }
get() { printf '%s' "notice-pw-contents"; echo 'New update available: v1 -> v2 (run "pass-cli update")' >&2; }
put() { exit 2; }
unlock() { exit 2; }
case "$cmd" in id) id;; describe) describe;; available) available;; setup) setup;; get) get;; put) put;; unlock) unlock;; *) exit 2;; esac
NBEOF
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/secrets/notice_backend"

config_set secrets.backend notice_backend
unset NAS_BACKUP_SECRETS_NOTICE NAS_BACKUP_SECRETS_ERRTEXT
secrets_try_get notice_backend || fail "test 17: get should succeed"
[[ -n "${NAS_BACKUP_SECRETS_NOTICE:-}" ]] \
  || fail "test 17a: NAS_BACKUP_SECRETS_NOTICE should be set after success"
echo "$NAS_BACKUP_SECRETS_NOTICE" | grep -qi "new update available" \
  || fail "test 17b: notice should contain 'New update available': got '$NAS_BACKUP_SECRETS_NOTICE'"
[[ -z "${NAS_BACKUP_SECRETS_ERRTEXT:-}" ]] \
  || fail "test 17c: ERRTEXT should be empty on success"

config_set secrets.backend dummy
unset NAS_BACKUP_SECRETS_NOTICE
secrets_try_get dummy || fail "test 17d: dummy get should succeed"
[[ -z "${NAS_BACKUP_SECRETS_NOTICE:-}" ]] \
  || fail "test 17d: dummy backend should not set NOTICE"

echo OK
