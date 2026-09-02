#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
source "$ROOT/tests/helpers.sh"
omaclone_test_env
unset NAS_BACKUP_LIB_LOADED
source "$ROOT/scripts/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -nE 'sudo[[:space:]]+(-n[[:space:]]+)?"?\$ROOT/scripts/prep.sh' "$ROOT/scripts/cmd-clone.sh" \
  && fail "cmd-clone must not sudo prep.sh"
grep -nE 'sudo[[:space:]]+".*prep.sh"' "$ROOT/scripts/cmd-clone.sh" \
  && fail "cmd-clone must not sudo a path to prep.sh"

etc_rel_ok fido2 || fail "fido2 should be allowed"
etc_rel_ok fstab && fail "fstab must be denied"
etc_rel_ok 'ld.so.conf.d' && fail "ld.so.conf.d must be denied"
etc_rel_ok 'cron.hourly' && fail "cron.hourly must be denied"
etc_rel_ok initcpio && fail "initcpio must be denied"
etc_rel_ok '../shadow' && fail "../shadow must be denied"
etc_rel_ok 'fido2/./evil' && fail "fido2/./evil must be denied"
etc_rel_ok 'fido2;id' && fail "fido2;id must be denied"
etc_rel_ok $'fido2\nshadow' && fail "newline rel must be denied"

victim=$(mktemp)
printf '%s\n' ORIGINAL_SECRET_CONTENT >"$victim"
mkdir -p "$NAS_BACKUP_STAGING"
ln -sfn "$victim" "$NAS_BACKUP_STAGING/etc.tar"
ln -sfn "$victim" "$NAS_BACKUP_STAGING/meta.txt"
# Prep recreates staging; sudo tar will fail in this hermetic env and write an empty tar.
set +e
"$ROOT/scripts/prep.sh" >/dev/null 2>&1
set -e
grep -q ORIGINAL_SECRET_CONTENT "$victim" || fail "prep overwrote symlink target"
[[ -d "$NAS_BACKUP_STAGING" ]] || fail "prep should recreate staging as a directory"
[[ ! -L "$NAS_BACKUP_STAGING" ]] || fail "staging must not be a symlink"
rm -f "$victim"

echo OK
