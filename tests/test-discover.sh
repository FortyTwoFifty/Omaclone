#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

kit=$(mktemp -d)
repo_only=$(mktemp -d)
empty=$(mktemp -d)
root_dump=$(mktemp -d)
trap 'rm -rf "$kit" "$repo_only" "$empty" "$root_dump"' EXIT

mkdir -p "$kit/omaclone"
touch "$kit/omaclone/restore" "$kit/omaclone/config.toml"
mkdir -p "$repo_only/omaclone/repo"
touch "$repo_only/omaclone/repo/config"
touch "$root_dump/restore" "$root_dump/config.toml"

export OMACLONE_DISCOVER_TARGETS="$kit
$repo_only
$empty
$root_dump"

out=$(python3 "$ROOT/scripts/discover_bootstrap.py")
echo "$out" | grep -q "$kit/omaclone" || fail "kit with restore+config.toml not found: $out"
echo "$out" | grep -q "$repo_only/omaclone" || fail "restic repo/config not found: $out"
echo "$out" | grep -q "$empty" && fail "empty mount must not be discovered: $out"
echo "$out" | grep -q "$root_dump" && fail "root-level dump must not be discovered: $out"

python3 - "$ROOT/scripts/discover_bootstrap.py" <<'PY'
import importlib.util
import sys
from pathlib import Path

path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("discover_bootstrap", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.backend_for_fstype("nfs4") == "nfs"
assert mod.backend_for_fstype("nfs") == "nfs"
assert mod.backend_for_fstype("cifs") == "cifs"
assert mod.backend_for_fstype("fuse.sshfs") == "sftp"
assert mod.backend_for_fstype("fuse.sftp") == "sftp"
assert mod.backend_for_fstype("ext4") == "disk"
assert mod.backend_for_fstype("") == "disk"
assert mod.backend_for_fstype("autofs") == "disk"

def _fake_fstype(output):
    import subprocess
    def check_output(*args, **kwargs):
        return output
    orig = subprocess.check_output
    subprocess.check_output = check_output
    try:
        return mod._fstype("/mnt/Omaclone-NAS")
    finally:
        subprocess.check_output = orig

assert _fake_fstype("autofs\nnfs4\n") == "nfs4"
assert _fake_fstype("autofs\n") == ""
assert _fake_fstype("exfat\n") == "exfat"
PY

kit=$(mktemp -d)
mkdir -p "$kit/omaclone"
touch "$kit/omaclone/restore" "$kit/omaclone/config.toml"
ln -s "$kit" "${kit}-link"
export OMACLONE_DISCOVER_TARGETS="$kit
${kit}-link"
out_dedup=$(python3 "$ROOT/scripts/discover_bootstrap.py")
n_kit=$(echo "$out_dedup" | grep -c "$kit/omaclone" || true)
[[ "$n_kit" == 1 ]] || fail "dedup kit+symlink: expected 1, got $n_kit (output: $out_dedup)"

kit2=$(mktemp -d)
mkdir -p "$kit2/omaclone"
touch "$kit2/omaclone/restore" "$kit2/omaclone/config.toml"
export OMACLONE_DISCOVER_TARGETS="$kit
$kit2"
out_two=$(python3 "$ROOT/scripts/discover_bootstrap.py")
n_kit1=$(echo "$out_two" | grep -c "$kit/omaclone" || true)
n_kit2=$(echo "$out_two" | grep -c "$kit2/omaclone" || true)
[[ "$n_kit1" == 1 ]] || fail "distinct kit1: expected 1, got $n_kit1"
[[ "$n_kit2" == 1 ]] || fail "distinct kit2: expected 1, got $n_kit2"

python3 - "$ROOT/scripts/discover_bootstrap.py" <<'PY'
import importlib.util, sys, json
from pathlib import Path

path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("discover_bootstrap", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

orig_resolve = mod._resolve_identity
def patched_resolve(path_str):
    return ("uuid", "SHARED-UUID")
mod._resolve_identity = patched_resolve

import tempfile, os
kit_a = tempfile.mkdtemp()
kit_b = tempfile.mkdtemp()
os.makedirs(os.path.join(kit_a, "omaclone"))
os.makedirs(os.path.join(kit_b, "omaclone"))
open(os.path.join(kit_a, "omaclone", "restore"), "w").close()
open(os.path.join(kit_a, "omaclone", "config.toml"), "w").close()
open(os.path.join(kit_b, "omaclone", "restore"), "w").close()
open(os.path.join(kit_b, "omaclone", "config.toml"), "w").close()
mod._targets = lambda: [kit_a, kit_b]

import io
buf = io.StringIO()
old_stdout = sys.stdout
sys.stdout = buf
try:
    mod.main()
finally:
    sys.stdout = old_stdout
lines = [l for l in buf.getvalue().strip().split("\n") if l.strip()]
assert len(lines) == 1, f"Expected 1 record for shared UUID, got {len(lines)}: {lines}"
PY

echo OK
