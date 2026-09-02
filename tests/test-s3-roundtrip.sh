#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
export NAS_BACKUP_ROOT="$ROOT"

MINIO_IMAGE="${OMACLONE_MINIO_IMAGE:-minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e}"

skip_or_fail() {
  local msg="$1"
  if [[ "${OMACLONE_REQUIRE_S3:-}" == 1 ]]; then
    fail "$msg"
  fi
  printf 'SKIP %s\n' "$msg"
  exit 0
}

need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
need restic
need jq
need rsync
need python3
need curl

REAL_HOME="${HOME}"
omaclone_test_env
omaclone_test_file_keyring
omaclone_install_dummy_secrets

ACCESS="minioaccess"
SECRET="minio-test-secret-xx"
BUCKET="omaclone-test"
PREFIX="omaclone"
REGION="us-east-1"
CONTAINER=""
MINIO_PID=""
MINIO_DATA=""
PORT=""
LIVE=0

wait_minio() {
  local port="$1" i
  for i in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:${port}/minio/health/live" >/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

cleanup_minio() {
  if [[ -n "$CONTAINER" ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MINIO_PID" ]]; then
    kill "$MINIO_PID" >/dev/null 2>&1 || true
    wait "$MINIO_PID" >/dev/null 2>&1 || true
  fi
  [[ -n "$MINIO_DATA" ]] && rm -rf "$MINIO_DATA"
  omaclone_test_cleanup 2>/dev/null || rm -rf "${OMACLONE_TEST_HOME:-}"
}
trap cleanup_minio EXIT

if [[ -n "${OMACLONE_S3_LIVE_ENDPOINT:-}" ]]; then
  LIVE=1
  PORT=""
  endpoint="$OMACLONE_S3_LIVE_ENDPOINT"
  endpoint="${endpoint#https://}"
  endpoint="${endpoint#http://}"
  BUCKET="${OMACLONE_S3_LIVE_BUCKET:?OMACLONE_S3_LIVE_BUCKET is required for live S3}"
  ACCESS="${OMACLONE_S3_LIVE_ACCESS_KEY:?OMACLONE_S3_LIVE_ACCESS_KEY is required for live S3}"
  SECRET="${OMACLONE_S3_LIVE_SECRET_KEY:?OMACLONE_S3_LIVE_SECRET_KEY is required for live S3}"
  tls="${OMACLONE_S3_LIVE_TLS:-1}"
else
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  started=0
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER="omaclone-minio-$$"
    if docker run -d --name "$CONTAINER" \
      -p "127.0.0.1:${PORT}:9000" \
      -e "MINIO_ROOT_USER=$ACCESS" \
      -e "MINIO_ROOT_PASSWORD=$SECRET" \
      "$MINIO_IMAGE" server /data >/dev/null; then
      if wait_minio "$PORT"; then
        started=1
      else
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
        CONTAINER=""
      fi
    else
      CONTAINER=""
    fi
  fi
  if (( ! started )); then
    cache="${XDG_CACHE_HOME:-$REAL_HOME/.cache}/omaclone-tests"
    mkdir -p "$cache"
    minio_bin="$cache/minio"
    if [[ ! -x "$minio_bin" ]]; then
      curl -fsSL -o "$minio_bin" \
        "https://dl.min.io/server/minio/release/linux-amd64/minio" \
        || skip_or_fail "could not download MinIO server binary"
      chmod +x "$minio_bin"
    fi
    MINIO_DATA=$(mktemp -d)
    MINIO_ROOT_USER="$ACCESS" MINIO_ROOT_PASSWORD="$SECRET" \
      "$minio_bin" server --address "127.0.0.1:${PORT}" "$MINIO_DATA" \
      >/tmp/omaclone-minio.$$ 2>&1 &
    MINIO_PID=$!
    if ! wait_minio "$PORT"; then
      cat /tmp/omaclone-minio.$$ >&2 || true
      skip_or_fail "MinIO server did not become healthy on port $PORT"
    fi
    started=1
  fi
  (( started )) || skip_or_fail "could not start MinIO"
  endpoint="127.0.0.1:${PORT}"
  tls=0
  AWS_ACCESS_KEY_ID="$ACCESS" AWS_SECRET_ACCESS_KEY="$SECRET" \
    python3 "$ROOT/tests/s3_create_bucket.py" "$endpoint" "$BUCKET" \
    || fail "CreateBucket $BUCKET failed"
fi

# Load _restic_url from the backend without dispatch.
_s3_lib=$(mktemp)
sed '$d' "$ROOT/backends/transport/s3" >"$_s3_lib"
# shellcheck disable=SC1090
source "$_s3_lib"
rm -f "$_s3_lib"

omaclone_test_cfg transport.backend s3
omaclone_test_cfg transport.preset minio
omaclone_test_cfg transport.endpoint "$endpoint"
omaclone_test_cfg transport.bucket "$BUCKET"
omaclone_test_cfg transport.prefix "$PREFIX"
omaclone_test_cfg transport.region "$REGION"
omaclone_test_cfg transport.tls "$tls"
repo=$(_restic_url)
omaclone_test_cfg restic.repo "$repo"
omaclone_test_cfg secrets.backend dummy
omaclone_test_cfg secrets.keyring_offer declined
omaclone_test_cfg destination.profile cloud
omaclone_test_cfg retention.preset last-5
omaclone_test_cfg locations.ids cloud
omaclone_test_cfg locations.active cloud
omaclone_test_cfg locations.cloud.backend s3
omaclone_test_cfg locations.cloud.repo "$repo"
omaclone_test_cfg locations.cloud.endpoint "$endpoint"
omaclone_test_cfg locations.cloud.bucket "$BUCKET"
omaclone_test_cfg locations.cloud.prefix "$PREFIX"
omaclone_test_cfg locations.cloud.region "$REGION"
omaclone_test_cfg locations.cloud.tls "$tls"
omaclone_test_cfg locations.cloud.label "Cloud (S3)"
omaclone_test_cfg locations.cloud.profile cloud
omaclone_test_cfg locations.cloud.schedule on

omaclone_test_put_transport_secret s3-access-key "$ACCESS"
omaclone_test_put_transport_secret s3-secret-key "$SECRET"

mkdir -p "$HOME/identity" "$HOME/.config/omaclone-app"
printf 'hello-from-%s\n' "omaclone-s3" >"$HOME/identity/marker.txt"
printf 'dotfile\n' >"$HOME/.config/omaclone-app/settings"

omaclone_cli init || fail "omaclone init against S3 failed"
omaclone_cli clone --cron >/tmp/omaclone-s3-clone.$$ 2>&1 \
  || { cat /tmp/omaclone-s3-clone.$$; fail "clone --cron against S3 failed"; }
rm -f /tmp/omaclone-s3-clone.$$
[[ "$(omaclone_last_result status)" == ok ]] \
  || fail "clone did not write last-result ok: $(omaclone_last_result status) $(omaclone_last_result message)"

grep -q "$SECRET" "$NAS_BACKUP_CONFIG" && fail "secret leaked into config.toml"
grep -q "$ACCESS" "$NAS_BACKUP_CONFIG" && fail "access key leaked into config.toml"
card="$NAS_BACKUP_STATE_DIR/RECOVERY.md"
if [[ -f "$card" ]]; then
  grep -Fq "$SECRET" "$card" && fail "secret leaked into recovery card"
  grep -Fq "$ACCESS" "$card" && fail "access key leaked into recovery card"
fi
if [[ -f "$NAS_BACKUP_STATE_DIR/last-result.json" ]]; then
  grep -Fq "$SECRET" "$NAS_BACKUP_STATE_DIR/last-result.json" && fail "secret leaked into last-result"
  grep -Fq "$ACCESS" "$NAS_BACKUP_STATE_DIR/last-result.json" && fail "access key leaked into last-result"
fi

pwfile=$(mktemp)
printf '%s' "dummy-password-not-for-real-repos" >"$pwfile"
export AWS_ACCESS_KEY_ID="$ACCESS" AWS_SECRET_ACCESS_KEY="$SECRET" AWS_DEFAULT_REGION="$REGION"
n=$(restic --password-file "$pwfile" --repo "$repo" snapshots --json | jq 'length')
[[ "$n" -ge 1 ]] || fail "expected at least 1 restic snapshot, got $n"
sid=$(restic --password-file "$pwfile" --repo "$repo" snapshots --json | jq -r '.[0].short_id')
[[ -n "$sid" && "$sid" != null ]] || fail "could not read snapshot id"

# Connecting to an existing cloud repo must query clone count (not wait for
# another clone/prune on this machine).
rm -f "$NAS_BACKUP_STATE_DIR"/repo-stats*.json
json=$(omaclone_cli status --json)
snaps=$(printf '%s' "$json" | jq -r '.snapshotCount')
[[ "$snaps" == "-1" ]] || fail "s3 status without cache should be unknown, got $snaps"
label=$(omaclone_cli location stats) || fail "location stats against live S3 failed"
[[ "$label" == *"clone"* ]] || fail "location stats label: $label"
json=$(omaclone_cli status --json)
snaps=$(printf '%s' "$json" | jq -r '.snapshotCount')
[[ "$snaps" -ge 1 ]] || fail "connect query did not cache clone count: $snaps ($json)"
locn=$(printf '%s' "$json" | jq -r '.locations[] | select(.id=="cloud") | .snapshotCount')
[[ "$locn" -ge 1 ]] || fail "location list missing queried clone count: $locn ($json)"

omaclone_cli check || fail "omaclone check failed"
omaclone_cli verify || fail "omaclone verify failed"

# Prefix isolation: a different prefix is a different repo.
other="${repo%/omaclone}/other"
case "$repo" in
  */omaclone) ;;
  *) other="${repo}/../other" ;;
esac
# Rebuild other prefix URL from the same host/bucket.
if [[ "$tls" == 0 ]]; then
  other="s3:http://${endpoint}/${BUCKET}/other"
else
  other="s3:https://${endpoint}/${BUCKET}/other"
fi
set +e
other_n=$(restic --password-file "$pwfile" --repo "$other" snapshots --json 2>/dev/null | jq 'length')
other_rc=$?
set -e
if (( other_rc == 0 )); then
  [[ "$other_n" == 0 ]] || fail "prefix isolation: other prefix saw $other_n snapshots"
fi

rm -f "$HOME/identity/marker.txt" "$HOME/.config/omaclone-app/settings"
rmdir "$HOME/.config/omaclone-app" 2>/dev/null || true
[[ ! -e "$HOME/identity/marker.txt" ]] || fail "pre-restore cleanup left marker.txt"

omaclone_cli restore --snapshot "$sid" --blank-omarchy >/tmp/omaclone-s3-restore.$$ 2>&1 \
  || { cat /tmp/omaclone-s3-restore.$$; fail "restore --snapshot failed"; }
rm -f /tmp/omaclone-s3-restore.$$
[[ -f "$HOME/identity/marker.txt" ]] || fail "restore did not write identity/marker.txt"
got=$(cat "$HOME/identity/marker.txt")
[[ "$got" == "hello-from-omaclone-s3" ]] || fail "restored marker mismatch: $got"
[[ -f "$HOME/.config/omaclone-app/settings" ]] || fail "restore did not write dotfile"

restic --password-file "$pwfile" --repo "$repo" unlock >/dev/null 2>&1 || true
omaclone_cli forget --yes "$sid"
left=$(restic --password-file "$pwfile" --repo "$repo" snapshots --json | jq 'length')
[[ "$left" == 0 ]] || fail "forget left $left snapshot(s)"

# Wrong secret key: clone must fail closed and not print the secret.
# restic/minio-go retries on 403; cap the wait so CI cannot hang.
omaclone_test_put_transport_secret s3-secret-key "this-is-the-wrong-secret"
rm -f "$NAS_BACKUP_STATE_DIR"/last-result*.json
set +e
out=$(timeout -k 2 20 "$NAS_BACKUP_ROOT/scripts/omaclone" clone --cron </dev/null 2>&1)
rc=$?
set -e
(( rc != 0 )) || fail "clone with wrong S3 secret should fail: $out"
printf '%s\n' "$out" | grep -q "this-is-the-wrong-secret" && fail "clone error leaked the secret"
if [[ -f "$NAS_BACKUP_STATE_DIR/last-result.json" ]]; then
  [[ "$(omaclone_last_result status)" == fail ]] \
    || fail "wrong key: expected last-result fail, got $(omaclone_last_result status)"
  printf '%s\n' "$(omaclone_last_result message)" | grep -q "this-is-the-wrong-secret" \
    && fail "last-result leaked the secret"
fi

# Restore the good secret; unreachable endpoint fails closed.
# (MinIO will auto-create a missing bucket, so a closed port is the fail-closed case.)
omaclone_test_put_transport_secret s3-secret-key "$SECRET"
if (( ! LIVE )); then
  omaclone_test_cfg transport.endpoint "127.0.0.1:1"
  omaclone_test_cfg restic.repo "s3:http://127.0.0.1:1/${BUCKET}/${PREFIX}"
  omaclone_test_cfg locations.cloud.repo "s3:http://127.0.0.1:1/${BUCKET}/${PREFIX}"
  set +e
  out=$(timeout -k 2 20 "$NAS_BACKUP_ROOT/scripts/omaclone" init </dev/null 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail "init to unreachable endpoint should fail: $out"
fi

# bootstrap-install is a no-op (no objects planted by omaclone itself).
set +e
out=$("$ROOT/backends/transport/s3" bootstrap-install 2>&1)
rc=$?
set -e
(( rc == 0 )) || fail "bootstrap-install: $out"

rm -f "$pwfile"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
echo OK
