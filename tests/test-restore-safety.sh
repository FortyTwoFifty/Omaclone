#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env
fail() { echo "FAIL: $*" >&2; exit 1; }

"$ROOT/scripts/omaclone" -h | grep -q -- '--blank-omarchy' || fail "usage missing --blank-omarchy"
"$ROOT/scripts/omaclone" -h | grep -q -- '--delete' || fail "usage missing --delete"

dest=$(mktemp -d)
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
[[ -f "$dest/SHA256SUMS" ]] || fail "bootstrap SHA256SUMS missing"

# Tampered kit must refuse to exec without UNTRUSTED (no plugin under temp HOME).
printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000  scripts/omaclone" >"$dest/SHA256SUMS"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "tampered kit restore should fail: $out"
printf '%s\n' "$out" | grep -qi "SHA256SUMS\|UNTRUSTED\|changed" \
  || fail "tampered kit should mention hash: $out"

# Tampered secrets backend must fail even if SHA256SUMS still lists the old trio.
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
printf '%s\n' '#!/bin/bash' 'echo stolen' >"$dest/omaclone/backends/secrets/prompt"
chmod +x "$dest/omaclone/backends/secrets/prompt"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "tampered prompt backend should fail hash: $out"
printf '%s\n' "$out" | grep -qi "SHA256SUMS\|UNTRUSTED\|changed" \
  || fail "tampered backend should mention hash: $out"

# Good hashes: launcher should get past the hash check (it may fail later on setup).
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | grep -qi "SHA256SUMS\|UNTRUSTED" && fail "good kit should not warn about hash: $out"

# Kit config must not copy secret-looking keys.
cat >"$NAS_BACKUP_CONFIG" <<'EOF'
[restic]
repo = "/mnt/omaclone/omaclone/repo"
[secrets]
backend = "prompt"
password = "SHOULD-NEVER-BE-HERE"
[s3]
secret_key = "also-should-not"
[transport]
backend = "local"
EOF
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
grep -q 'SHOULD-NEVER-BE-HERE' "$dest/config.toml" && fail "kit config copied secrets.password"
grep -q 'also-should-not' "$dest/config.toml" && fail "kit config copied s3.secret_key"
grep -q 'backend = "prompt"' "$dest/config.toml" || fail "kit config should keep secrets.backend"

grep -q '  scripts/restore$' "$dest/SHA256SUMS" || fail "SHA256SUMS must list scripts/restore"
grep -q '  config/excludes.txt$' "$dest/SHA256SUMS" || fail "SHA256SUMS must list config/excludes.txt"
grep -q '  config/etc-restore.allow$' "$dest/SHA256SUMS" || fail "SHA256SUMS must list config/etc-restore.allow"
grep -q '  config/hardware-packages.txt$' "$dest/SHA256SUMS" || fail "SHA256SUMS must list config/hardware-packages.txt"
grep -q '  config/user-units.deny$' "$dest/SHA256SUMS" || fail "SHA256SUMS must list config/user-units.deny"

# Tamper only the outer launcher; inner SHA256SUMS still matches the plugin tree.
python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
printf '\n# pwned\n' >>"$dest/restore"
set +e
out=$("$dest/restore" --blank-omarchy </dev/null 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "tampered outer restore should fail: $out"
printf '%s\n' "$out" | grep -qi "SHA256SUMS\|UNTRUSTED\|changed" \
  || fail "tampered outer restore should mention hash: $out"

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/cmd-restore.sh"
grep -q 'OMACLONE_TEST' "$ROOT/scripts/cmd-restore.sh" \
  || fail "--blank-omarchy must be gated on OMACLONE_TEST"

export XDG_RUNTIME_DIR="$OMACLONE_TEST_HOME/runtime"
mkdir -p "$XDG_RUNTIME_DIR"
staging=$(_restore_staging_dir)
case "$staging" in
  "$NAS_BACKUP_STATE_DIR"/restore-staging/*) ;;
  *) fail "staging not under state dir: $staging" ;;
esac
case "$staging" in
  "$XDG_RUNTIME_DIR"*) fail "staging must not use XDG_RUNTIME_DIR: $staging" ;;
esac
rm -rf "$staging"

got=$(_restore_rsync_excludes)
printf '%s\n' "$got" | grep -Fx '.local/share/Steam' >/dev/null || fail "excludes must keep Steam"
printf '%s\n' "$got" | grep -Fx '.ollama' >/dev/null || fail "excludes must keep ollama"

rsrc=$(mktemp -d)
rdst=$(mktemp -d)
mkdir -p "$rsrc/keep" "$rdst/.local/share/Steam" "$rdst/.ollama"
echo home >"$rsrc/keep/file"
echo game >"$rdst/.local/share/Steam/app"
echo model >"$rdst/.ollama/m"
echo extra >"$rdst/extra-should-go"
rsync_excludes=()
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  rsync_excludes+=(--exclude "$rel")
done < <(_restore_rsync_excludes)
rsync -a --delete "${rsync_excludes[@]}" "$rsrc"/ "$rdst"/ >/dev/null 2>&1
[[ -f "$rdst/.local/share/Steam/app" ]] || fail "--delete wiped Steam fixture"
[[ -f "$rdst/.ollama/m" ]] || fail "--delete wiped ollama fixture"
[[ -f "$rdst/keep/file" ]] || fail "identity file missing after rsync"
[[ ! -f "$rdst/extra-should-go" ]] || fail "--delete should remove extra dest files outside excludes"
rm -rf "$rsrc" "$rdst"

tardir=$(mktemp -d)
mkdir -p "$tardir/etc/fido2"
echo ok >"$tardir/etc/fido2/ok"
python3 - "$tardir" <<'PY'
import io, tarfile, pathlib, sys
root = pathlib.Path(sys.argv[1])
tarpath = root / "etc.tar"
with tarfile.open(tarpath, "w") as tf:
    tf.add(root / "etc/fido2/ok", arcname="etc/fido2/ok")
    info = tarfile.TarInfo("../omaclone-tar-slip-outside")
    info.size = 5
    tf.addfile(info, io.BytesIO(b"pwned"))
    info2 = tarfile.TarInfo("etc/../evil")
    info2.size = 4
    tf.addfile(info2, io.BytesIO(b"bad\n"))
PY
extract=$(mktemp -d)
_restore_extract_etc_tar "$tardir/etc.tar" "$extract"
[[ -f "$extract/etc/fido2/ok" ]] || fail "allowlisted etc member missing"
[[ ! -e "$extract/omaclone-tar-slip-outside" ]] || fail "tar ../ member extracted inside dest"
[[ ! -e "$(dirname "$extract")/omaclone-tar-slip-outside" ]] || fail "tar ../ member escaped"
[[ ! -e "$extract/evil" ]] || fail "tar etc/../ member escaped"
rm -rf "$tardir" "$extract"

python3 "$ROOT/scripts/bootstrap_copy.py" "$ROOT" "$dest" "$NAS_BACKUP_CONFIG"
old_root=$NAS_BACKUP_ROOT
NAS_BACKUP_ROOT="$dest/omaclone"
omaclone_root_is_kit || fail "kit tree should be detected as a kit"
if omaclone_link_cli >/dev/null 2>&1; then
  fail "install from kit must not symlink PATH"
fi
[[ ! -L "$HOME/.local/bin/omaclone" ]] || fail "kit install left PATH symlink"
if omaclone_link_plugin >/dev/null 2>&1; then
  fail "install from kit must not symlink plugin"
fi
NAS_BACKUP_ROOT=$old_root

rm -rf "$dest"
echo OK
