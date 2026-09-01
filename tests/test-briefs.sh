#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NAS_BACKUP_ROOT="$ROOT"
export NAS_BACKUP_USER_CONFIG_DIR
NAS_BACKUP_USER_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$NAS_BACKUP_USER_CONFIG_DIR"' EXIT
export NAS_BACKUP_CONFIG="$NAS_BACKUP_USER_CONFIG_DIR/config.toml"
mkdir -p "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport"
cp "$ROOT/tests/backends/transport/dummy" "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport/dummy"
chmod +x "$NAS_BACKUP_USER_CONFIG_DIR/backends/transport/dummy"

source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/backend.sh"
source "$ROOT/scripts/tui.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

need_file() {
  local f="$ROOT/briefs/$1.txt"
  [[ -f "$f" ]] || fail "missing brief: $f"
}

need_file nfs
need_file cifs
need_file sftp
need_file s3-aws
need_file secrets-keyring
need_file secrets-1password
need_file secrets-pass-cli
need_file secrets-prompt

# Hints are plain sentences, not markdown cards.
if grep -R -n -E '`|\*\*|```|^#' "$ROOT/briefs"/*.txt; then
  fail "wizard hints must be plain text (no markdown)"
fi
if grep -R -n "Omaclone Password" "$ROOT/briefs" "$ROOT/scripts/cmd-setup.sh" \
    "$ROOT/backends/secrets" "$ROOT/backends/transport" 2>/dev/null; then
  fail "wizard copy must not mention a personal Proton Pass item title"
fi
if grep -R -n -E 'IAM role ARN|not an ARN' "$ROOT/briefs"; then
  fail "wizard hints should not lead with ARN jargon"
fi

grep -q 'Mapall' "$ROOT/briefs/nfs.txt" || fail "NFS hint should mention Mapall"
grep -q 'ssh-copy-id' "$ROOT/briefs/sftp.txt" || fail "SFTP hint should mention ssh-copy-id"
grep -q 'only while this share is mounted' "$ROOT/briefs/cifs.txt" || fail "CIFS hint should say clones need the share mounted"
grep -q 'README' "$ROOT/briefs/s3-aws.txt" || fail "AWS hint should point at the README for IAM"
grep -q 'FIDO' "$ROOT/briefs/secrets-keyring.txt" || fail "keyring hint should mention FIDO"

# Renderer is gum style, not markdown format/pager.
grep -q 'gum format' "$ROOT/scripts/tui.sh" && fail "tui_brief should not use gum format"
grep -q 'gum pager' "$ROOT/scripts/tui.sh" && fail "tui_brief should not use gum pager"

# Do not stack a destination/S3 essay above the next picker.
if grep -q 'tui_brief_file destination' "$ROOT/scripts/cmd-setup.sh"; then
  fail "destination picker should not print a briefing card"
fi
if grep -q 'tui_brief_from_backend transport' "$ROOT/scripts/cmd-setup.sh"; then
  fail "transport hints belong next to that transport's fields, not before the provider picker"
fi
grep -q 'tui_brief_file nfs' "$ROOT/backends/transport/nfs" || fail "NFS setup should hint before the URI"
grep -q 'tui_brief_file s3-aws' "$ROOT/backends/transport/s3" || fail "AWS setup should hint before the bucket"
grep -q '_setup_pick_destination' "$ROOT/scripts/cmd-status.sh" || fail "location add should reuse destination setup"

# brief verb: field-adjacent backends print a line; others may be empty; unknown still fails.
for name in nfs cifs sftp; do
  out=$(nas_backup_backend_run transport "$name" brief) || fail "brief failed for transport/$name"
  [[ -n "$out" ]] || fail "brief empty for transport/$name"
done
nas_backup_backend_run transport s3 brief >/dev/null || fail "s3 brief should succeed (may be empty)"
got=$(nas_backup_backend_run transport dummy brief) || fail "dummy brief should succeed"
[[ -z "$got" ]] || fail "dummy brief should be empty, got: $got"
if nas_backup_backend_run transport dummy definitely-not-a-verb 2>/dev/null; then
  fail "unknown verb should still fail"
fi
out=$(nas_backup_backend_run secrets keyring brief) || fail "brief failed for secrets/keyring"
[[ -n "$out" ]] || fail "brief empty for secrets/keyring"

body=$(tui_brief_file nfs)
printf '%s\n' "$body" | grep -q 'Mapall' || fail "tui_brief_file nfs should print the Mapall hint"

# README holds copy-paste IAM and restore details.
grep -q 's3:ListBucket' "$ROOT/README.md" || fail "README should document s3:ListBucket"
grep -q 'arn:aws:s3:::BUCKET"' "$ROOT/README.md" || fail "README IAM bucket ARN should have no /*"
grep -q 'arn:aws:s3:::BUCKET/\*"' "$ROOT/README.md" || fail "README IAM object ARN should be BUCKET/*"
python3 - "$ROOT/README.md" <<'PY' || fail "README IAM JSON"
import json, re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"```json\s*(.*?)```", text, re.S)
if not m:
    raise SystemExit("missing json fence")
policy = json.loads(m.group(1))
list_ok = obj_ok = False
for stmt in policy["Statement"]:
    actions = stmt["Action"]
    if isinstance(actions, str):
        actions = [actions]
    res = stmt["Resource"]
    if "s3:ListBucket" in actions:
        if res.endswith("/*"):
            raise SystemExit(f"ListBucket resource must not end with /*: {res}")
        if res != "arn:aws:s3:::BUCKET":
            raise SystemExit(f"ListBucket resource: {res}")
        if "s3:GetBucketLocation" not in actions:
            raise SystemExit("ListBucket statement should include GetBucketLocation")
        list_ok = True
    if "s3:GetObject" in actions:
        if res != "arn:aws:s3:::BUCKET/*":
            raise SystemExit(f"object resource: {res}")
        for need in ("s3:PutObject", "s3:DeleteObject"):
            if need not in actions:
                raise SystemExit(f"missing {need} on objects")
        obj_ok = True
if not list_ok or not obj_ok:
    raise SystemExit("policy missing bucket or object statement")
PY
grep -q 'no `./restore`' "$ROOT/README.md" || fail "README should say S3 has no ./restore"
grep -q 'briefs/' "$ROOT/README.md" || fail "README layout should list briefs/"
grep -q 'Mapall' "$ROOT/README.md" || fail "README should document TrueNAS Mapall"

echo "OK"
