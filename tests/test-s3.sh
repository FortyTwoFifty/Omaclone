#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"
omaclone_test_env
omaclone_test_file_keyring
omaclone_install_dummy_secrets

S3="$ROOT/backends/transport/s3"

# Load backend functions without running dispatch_transport.
_s3_lib=$(mktemp)
sed '$d' "$S3" >"$_s3_lib"
# shellcheck disable=SC1090
source "$_s3_lib"
rm -f "$_s3_lib"

expect_url() {
  local want="$1" got
  got=$(_restic_url)
  [[ "$got" == "$want" ]] || fail "restic url: got '$got' want '$want'"
}

cfg_s3() {
  omaclone_test_cfg transport.backend s3
  omaclone_test_cfg transport.endpoint "$1"
  omaclone_test_cfg transport.bucket "$2"
  omaclone_test_cfg transport.prefix "${3:-omaclone}"
  omaclone_test_cfg transport.tls "${4:-1}"
}

# --- presets ---
[[ "$(_preset_endpoint aws)" == s3.amazonaws.com ]] || fail "aws preset"
[[ "$(_preset_endpoint r2)" == "" ]] || fail "r2 preset should be empty"
[[ "$(_preset_endpoint wasabi)" == s3.wasabisys.com ]] || fail "wasabi preset"
[[ -z "$(_preset_endpoint b2)" ]] || fail "b2 preset should be empty (endpoint comes from the B2 console)"
[[ "$(_preset_endpoint minio)" == "" ]] || fail "minio preset should be empty"
[[ "$(_preset_endpoint "")" == "" ]] || fail "empty preset"
[[ "$(_preset_endpoint nope)" == "" ]] || fail "unknown preset"

# --- URL construction ---
cfg_s3 s3.amazonaws.com mybucket omaclone 1
expect_url "s3:s3.amazonaws.com/mybucket/omaclone"

cfg_s3 s3.us-west-2.amazonaws.com mybucket omaclone 1
expect_url "s3:s3.us-west-2.amazonaws.com/mybucket/omaclone"

cfg_s3 s3.dualstack.us-east-1.amazonaws.com mybucket omaclone 1
expect_url "s3:s3.dualstack.us-east-1.amazonaws.com/mybucket/omaclone"

cfg_s3 acct.r2.cloudflarestorage.com mybucket omaclone 1
expect_url "s3:https://acct.r2.cloudflarestorage.com/mybucket/omaclone"

cfg_s3 s3.wasabisys.com mybucket omaclone 1
expect_url "s3:https://s3.wasabisys.com/mybucket/omaclone"

cfg_s3 s3.us-west-000.backblazeb2.com mybucket omaclone 1
expect_url "s3:https://s3.us-west-000.backblazeb2.com/mybucket/omaclone"

cfg_s3 127.0.0.1:9000 mybucket omaclone 0
expect_url "s3:http://127.0.0.1:9000/mybucket/omaclone"

cfg_s3 127.0.0.1:9000 mybucket omaclone 1
expect_url "s3:https://127.0.0.1:9000/mybucket/omaclone"

# Strip pasted schemes and trailing slash
cfg_s3 "https://minio.example:9000/" mybucket omaclone 0
expect_url "s3:http://minio.example:9000/mybucket/omaclone"

cfg_s3 "http://minio.example:9000/" mybucket omaclone 1
expect_url "s3:https://minio.example:9000/mybucket/omaclone"

# Prefix slash stripping
cfg_s3 minio.example mybucket "/foo/" 0
expect_url "s3:http://minio.example/mybucket/foo"

# Empty prefix: no trailing slash junk
omaclone_test_cfg transport.endpoint minio.example
omaclone_test_cfg transport.bucket mybucket
omaclone_test_cfg transport.prefix ""
omaclone_test_cfg transport.tls 0
expect_url "s3:http://minio.example/mybucket"

omaclone_test_cfg transport.endpoint s3.amazonaws.com
omaclone_test_cfg transport.bucket mybucket
omaclone_test_cfg transport.prefix ""
expect_url "s3:s3.amazonaws.com/mybucket"

# AWS region rewrites the legacy global endpoint
omaclone_test_cfg transport.prefix omaclone
omaclone_test_cfg transport.region us-west-2
expect_url "s3:s3.us-west-2.amazonaws.com/mybucket/omaclone"
omaclone_test_cfg transport.region us-east-1
expect_url "s3:s3.us-east-1.amazonaws.com/mybucket/omaclone"
omaclone_test_cfg transport.endpoint s3.us-west-2.amazonaws.com
omaclone_test_cfg transport.region us-west-2
expect_url "s3:s3.us-west-2.amazonaws.com/mybucket/omaclone"
omaclone_test_cfg transport.endpoint s3.amazonaws.com
omaclone_test_cfg transport.region ""

[[ "$(_s3_normalize_bucket '  omaclone  ')" == omaclone ]] || fail "trim bucket"
[[ "$(_s3_normalize_bucket 's3://omaclone')" == omaclone ]] || fail "s3:// bucket"
[[ "$(_s3_normalize_bucket 'https://s3.amazonaws.com/omaclone')" == omaclone ]] || fail "path-style url bucket"
[[ "$(_s3_normalize_bucket 'omaclone.s3.amazonaws.com')" == omaclone ]] || fail "virtual-host bucket"
[[ "$(_s3_normalize_bucket 's3.us-west-2.amazonaws.com/omaclone/restic')" == omaclone ]] || fail "regional path url"
[[ "$(_s3_normalize_key '  AKIAEXAMPLE  ')" == AKIAEXAMPLE ]] || fail "trim access key"
[[ "$(_s3_normalize_key 'AWS_ACCESS_KEY_ID=AKIAEXAMPLE')" == AKIAEXAMPLE ]] || fail "strip env prefix"
[[ "$(_s3_normalize_key '"AKIAquoted"')" == AKIAquoted ]] || fail "strip quotes"

got=$(python3 "$ROOT/scripts/s3_probe.py" "not a bucket")
[[ -z "$got" ]] || fail "probe should reject spaces: $got"
got=$(python3 "$ROOT/scripts/s3_probe.py" "foo/bar")
[[ -z "$got" ]] || fail "probe should reject slash: $got"

python3 - "$ROOT/scripts/s3_check.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("s3_check", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
url, uri, host = m.list_url("s3.us-west-2.amazonaws.com", "omaclone", "us-west-2", True)
assert uri == "/", uri
assert host.startswith("omaclone.s3.us-west-2.amazonaws.com"), host
url, uri, host = m.list_url("acct.r2.cloudflarestorage.com", "omaclone", "auto", True)
assert uri == "/omaclone", uri
assert host == "acct.r2.cloudflarestorage.com", host
url, uri, host = m.list_url("s3.wasabisys.com", "mybucket", "us-east-1", True)
assert uri == "/mybucket", uri
out = m.check_access("", "bucket", "us-east-1", "", "secret")
assert out["ok"] is False and out["code"] == "MissingInput"
print("s3_check helpers ok")
PY

# Default prefix when unset: cfg default is omaclone. Clear by not setting empty —
# config.py set "" is explicit empty; delete isn't available. Already covered above.

# --- contract verbs ---
run_s3() {
  NAS_BACKUP_KIND=transport NAS_BACKUP_BACKEND=s3 "$S3" "$@"
}

[[ "$(run_s3 id)" == s3 ]] || fail "id"
[[ "$(run_s3 capabilities)" == remote ]] || fail "capabilities: $(run_s3 capabilities)"
keys=$(run_s3 credential-keys)
printf '%s\n' "$keys" | grep -qx 's3-access-key' || fail "missing s3-access-key"
printf '%s\n' "$keys" | grep -qx 's3-secret-key' || fail "missing s3-secret-key"
[[ "$(printf '%s\n' "$keys" | wc -l)" == 2 ]] || fail "credential-keys extra lines: $keys"
run_s3 available || fail "available should succeed"

omaclone_test_cfg restic.repo "s3:https://example.invalid/mybucket/omaclone"
omaclone_test_cfg transport.backend s3
set +e
run_s3 ready >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "ready should fail without keys"

omaclone_test_put_transport_secret s3-access-key "AKIAEXAMPLE"
set +e
run_s3 ready >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "ready should fail with only access key"

omaclone_test_put_transport_secret s3-secret-key "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
run_s3 ready || fail "ready should succeed with both keys"

set +e
run_s3 mount
rc=$?
set -e
(( rc == 0 )) || fail "mount should match ready (success)"

omaclone_test_cfg restic.repo ""
set +e
run_s3 ready >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "ready should fail with empty restic.repo"

omaclone_test_cfg restic.repo "s3:https://example.invalid/mybucket/omaclone"

boot_dir=$(mktemp -d)
set +e
out=$(run_s3 bootstrap-install 2>&1)
rc=$?
set -e
(( rc == 0 )) || fail "bootstrap-install should exit 0: $out"
printf '%s\n' "$out" | grep -qi "plugin add\|no runnable" \
  || fail "bootstrap-install should mention plugin restore: $out"
n_files=$(find "$boot_dir" -mindepth 1 | wc -l)
[[ "$n_files" == 0 ]] || fail "bootstrap-install created files in $boot_dir"
rmdir "$boot_dir"

# --- pre-restic env file ---
envf=$(mktemp)
chmod 600 "$envf"
omaclone_test_cfg transport.region ""
NAS_BACKUP_ENVFILE="$envf" run_s3 pre-restic || fail "pre-restic failed"
[[ "$(stat -c %a "$envf")" == 600 ]] || fail "env file mode $(stat -c %a "$envf")"
# shellcheck disable=SC1090
set -a
source "$envf"
set +a
[[ "$AWS_ACCESS_KEY_ID" == AKIAEXAMPLE ]] || fail "AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
[[ "$AWS_SECRET_ACCESS_KEY" == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" ]] || fail "secret mismatch"
[[ -z "${AWS_DEFAULT_REGION:-}" ]] || fail "region should be omitted when unset: ${AWS_DEFAULT_REGION:-}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_EC2_METADATA_DISABLED
grep -q AKIAEXAMPLE "$NAS_BACKUP_CONFIG" && fail "access key leaked into config.toml"
grep -q wJalr "$NAS_BACKUP_CONFIG" && fail "secret leaked into config.toml"

omaclone_test_cfg transport.region us-west-2
: >"$envf"
NAS_BACKUP_ENVFILE="$envf" run_s3 pre-restic || fail "pre-restic with region failed"
# shellcheck disable=SC1090
set -a
source "$envf"
set +a
[[ "$AWS_DEFAULT_REGION" == us-west-2 ]] || fail "region: ${AWS_DEFAULT_REGION:-}"
[[ "$AWS_REGION" == us-west-2 ]] || fail "AWS_REGION: ${AWS_REGION:-}"
[[ "${AWS_EC2_METADATA_DISABLED:-}" == true ]] || fail "IMDS should be disabled: ${AWS_EC2_METADATA_DISABLED:-}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REGION AWS_EC2_METADATA_DISABLED

omaclone_test_put_transport_secret s3-session-token "session-token-example"
omaclone_test_cfg transport.role_arn "arn:aws:iam::123456789012:role/Omaclone"
: >"$envf"
NAS_BACKUP_ENVFILE="$envf" run_s3 pre-restic || fail "pre-restic with session/role failed"
# shellcheck disable=SC1090
set -a
source "$envf"
set +a
[[ "$AWS_SESSION_TOKEN" == "session-token-example" ]] || fail "session token: ${AWS_SESSION_TOKEN:-}"
[[ "$RESTIC_AWS_ASSUME_ROLE_ARN" == "arn:aws:iam::123456789012:role/Omaclone" ]] || fail "role arn: ${RESTIC_AWS_ASSUME_ROLE_ARN:-}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REGION AWS_SESSION_TOKEN RESTIC_AWS_ASSUME_ROLE_ARN AWS_EC2_METADATA_DISABLED
python3 "$ROOT/scripts/keyring_store.py" delete s3-session-token
omaclone_test_cfg transport.role_arn ""

# Special characters in keys must survive bash %q + source
omaclone_test_put_transport_secret s3-access-key "id with spaces"
omaclone_test_put_transport_secret s3-secret-key "sec'ret\$dollar"
: >"$envf"
NAS_BACKUP_ENVFILE="$envf" run_s3 pre-restic || fail "pre-restic quoted keys failed"
# shellcheck disable=SC1090
set -a
source "$envf"
set +a
[[ "$AWS_ACCESS_KEY_ID" == "id with spaces" ]] || fail "quoted access: $AWS_ACCESS_KEY_ID"
[[ "$AWS_SECRET_ACCESS_KEY" == "sec'ret\$dollar" ]] || fail "quoted secret: $AWS_SECRET_ACCESS_KEY"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

# Missing key is fail-closed
python3 "$ROOT/scripts/keyring_store.py" delete s3-secret-key
set +e
NAS_BACKUP_ENVFILE="$envf" run_s3 pre-restic >/dev/null 2>&1
rc=$?
set -e
(( rc != 0 )) || fail "pre-restic should fail when secret key is missing"

# Empty NAS_BACKUP_ENVFILE is a documented no-op
unset NAS_BACKUP_ENVFILE
run_s3 pre-restic || fail "pre-restic without envfile should no-op"

# password_cleanup shreds the env file
echo 'AWS_ACCESS_KEY_ID=x' >"$envf"
NAS_BACKUP_ROOT="$ROOT" NAS_BACKUP_ENVFILE="$envf" bash -c '
  set -euo pipefail
  source "$NAS_BACKUP_ROOT/scripts/lib.sh"
  password_cleanup
'
[[ ! -e "$envf" ]] || fail "env file not removed by password_cleanup"

# Restore keys for later CLI checks
omaclone_test_put_transport_secret s3-access-key "AKIAEXAMPLE"
omaclone_test_put_transport_secret s3-secret-key "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

# --- hygiene: recovery card / last-result ---
omaclone_test_cfg destination.profile cloud
omaclone_test_cfg transport.endpoint example.r2.cloudflarestorage.com
omaclone_test_cfg transport.bucket mybucket
omaclone_test_cfg restic.repo "s3:https://example.r2.cloudflarestorage.com/mybucket/omaclone"
card=$(NAS_BACKUP_ROOT="$ROOT" NAS_BACKUP_CONFIG="$NAS_BACKUP_CONFIG" \
  NAS_BACKUP_STATE_DIR="$NAS_BACKUP_STATE_DIR" bash -c '
    source "$NAS_BACKUP_ROOT/scripts/lib.sh"
    write_recovery_card
  ')
grep -q AKIAEXAMPLE "$card" && fail "recovery card leaked access key"
grep -q wJalr "$card" && fail "recovery card leaked secret"
printf '%s\n' '{"status":"ok","message":"backup completed","unix":1}' >"$NAS_BACKUP_STATE_DIR/last-result.json"
grep -q AKIAEXAMPLE "$NAS_BACKUP_STATE_DIR/last-result.json" && fail "last-result leaked key"

# restic_summarize_fail must not copy AWS keys (or any stderr snippet) into the user message
err=$(mktemp)
printf '%s\n' "Fatal: AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY AccessDenied" >"$err"
got=$(NAS_BACKUP_ROOT="$ROOT" NAS_BACKUP_CONFIG="$NAS_BACKUP_CONFIG" bash -c '
  source "$NAS_BACKUP_ROOT/scripts/lib.sh"
  restic_summarize_fail 1 "$1"
' bash "$err")
printf '%s\n' "$got" | grep -q wJalr && fail "summarize leaked secret: $got"
[[ "$got" == "Clone failed (restic exited 1)" ]] || fail "summarize should be generic, got: $got"
rm -f "$err"

# issue_is_disconnect is false for s3
NAS_BACKUP_ROOT="$ROOT" NAS_BACKUP_CONFIG="$NAS_BACKUP_CONFIG" bash -c '
  source "$NAS_BACKUP_ROOT/scripts/lib.sh"
  if issue_is_disconnect "Clone disk is not connected" s3; then
    exit 1
  fi
  if issue_is_disconnect "not mounted" s3; then
    exit 1
  fi
' || fail "s3 must not count as a disconnect skip"

# --- status / doctor ---
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg secrets.keyring_offer declined
omaclone_test_cfg locations.ids cloud
omaclone_test_cfg locations.active cloud
omaclone_test_cfg locations.cloud.backend s3
omaclone_test_cfg locations.cloud.repo "s3:https://example.r2.cloudflarestorage.com/mybucket/omaclone"
omaclone_test_cfg locations.cloud.label "Cloud (S3)"
omaclone_test_cfg locations.cloud.profile cloud
omaclone_test_cfg locations.cloud.schedule on
omaclone_test_cfg restic.initialized 1

json=$(omaclone_cli status --json)
ready=$(printf '%s' "$json" | jq -r '.transportReady')
conn=$(printf '%s' "$json" | jq -r '.connected')
snaps=$(printf '%s' "$json" | jq -r '.snapshotCount')
[[ "$ready" == true ]] || fail "status transportReady with keys: $ready ($json)"
[[ "$conn" == true ]] || fail "status connected should be true for s3: $conn"
[[ "$snaps" == "-1" ]] || fail "s3 without stats cache should not invent a clone count: $snaps"

printf '%s\n' '{"snapshotCount":7,"restoreSizeBytes":123,"packedSizeBytes":45,"locationId":"cloud"}' \
  >"$NAS_BACKUP_STATE_DIR/repo-stats-cloud.json"
json=$(omaclone_cli status --json)
snaps=$(printf '%s' "$json" | jq -r '.snapshotCount')
[[ "$snaps" == 7 ]] || fail "s3 status should use cached clone count: $snaps ($json)"
locn=$(printf '%s' "$json" | jq -r '.locations[] | select(.id=="cloud") | .snapshotCount')
[[ "$locn" == 7 ]] || fail "s3 location list should use cached clone count: $locn ($json)"

python3 "$ROOT/scripts/keyring_store.py" delete s3-access-key
python3 "$ROOT/scripts/keyring_store.py" delete s3-secret-key
json=$(omaclone_cli status --json)
ready=$(printf '%s' "$json" | jq -r '.transportReady')
conn=$(printf '%s' "$json" | jq -r '.connected')
[[ "$ready" == false ]] || fail "status transportReady without keys: $ready"
[[ "$conn" == true ]] || fail "s3 stays connected without keys: $conn"

doc=$(omaclone_cli doctor)
printf '%s\n' "$doc" | grep -q "mounted: n/a (remote transport)" \
  || fail "doctor should say remote transport: $doc"
printf '%s\n' "$doc" | grep -q "ready: NO" \
  || fail "doctor ready NO without keys: $doc"

omaclone_test_put_transport_secret s3-access-key "AKIAEXAMPLE"
omaclone_test_put_transport_secret s3-secret-key "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
doc=$(omaclone_cli doctor)
printf '%s\n' "$doc" | grep -q "ready: yes" \
  || fail "doctor ready yes with keys: $doc"

# copy dest s3 is rejected
mkdir -p "$HOME/local-repo"
omaclone_test_cfg transport.backend local
omaclone_test_cfg restic.repo "$HOME/local-repo"
omaclone_test_cfg locations.ids "local,cloud"
omaclone_test_cfg locations.active local
omaclone_test_cfg locations.local.backend local
omaclone_test_cfg locations.local.repo "$HOME/local-repo"
omaclone_test_cfg locations.local.label Local
set +e
out=$(omaclone_cli copy cloud 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "copy to s3 should fail: $out"
printf '%s\n' "$out" | grep -qi "mounted destinations" \
  || fail "copy to s3 should mention mounted destinations: $out"

echo OK
