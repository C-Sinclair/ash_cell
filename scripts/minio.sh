#!/usr/bin/env bash
#
# Starts MinIO and creates the test bucket, then waits for it to answer.
#
# Seventeen tests fail without an object store, and they fail loudly rather than
# skipping: the whole design rests on conditional-write semantics, so a mocked
# store would only ever confirm our own reading of them. That makes MinIO a build
# dependency rather than a convenience, which is why this is a script both CI and
# a laptop run rather than a paragraph in a README that drifts.
#
# Credentials and ports match config/config.exs. Change them in one place.
#
#   scripts/minio.sh          # start, create bucket, wait, exit 0
#   scripts/minio.sh --wait   # only wait for an instance someone else started
set -euo pipefail

ENDPOINT="${ASHCELL_S3_ENDPOINT:-http://127.0.0.1:9010}"
BUCKET="${ASHCELL_S3_BUCKET:-ashcell-test}"
ACCESS_KEY="${ASHCELL_S3_ACCESS_KEY_ID:-ashcell}"
SECRET_KEY="${ASHCELL_S3_SECRET_ACCESS_KEY:-ashcellsecret}"
DATA_DIR="${ASHCELL_MINIO_DIR:-${TMPDIR:-/tmp}/ashcell-minio}"
PORT="${ENDPOINT##*:}"

wait_for_minio() {
  for _ in $(seq 1 30); do
    if curl -sf "${ENDPOINT}/minio/health/live" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "minio did not become healthy at ${ENDPOINT} within 30s" >&2
  return 1
}

if [ "${1:-}" != "--wait" ]; then
  if curl -sf "${ENDPOINT}/minio/health/live" >/dev/null 2>&1; then
    echo "minio already running at ${ENDPOINT}"
  else
    command -v minio >/dev/null 2>&1 || {
      echo "minio not found on PATH. brew install minio, or see https://min.io/download" >&2
      exit 1
    }

    mkdir -p "${DATA_DIR}"
    MINIO_ROOT_USER="${ACCESS_KEY}" MINIO_ROOT_PASSWORD="${SECRET_KEY}" \
      minio server "${DATA_DIR}" --address ":${PORT}" >"${DATA_DIR}/minio.log" 2>&1 &
    echo "started minio at ${ENDPOINT} (log: ${DATA_DIR}/minio.log)"
  fi
fi

wait_for_minio

# The bucket has to exist before the first conditional write, and creating it is
# idempotent, so this runs on every start rather than only the first.
if command -v mc >/dev/null 2>&1; then
  mc alias set ashcell "${ENDPOINT}" "${ACCESS_KEY}" "${SECRET_KEY}" >/dev/null
  mc mb --ignore-existing "ashcell/${BUCKET}" >/dev/null
  echo "bucket ${BUCKET} ready"
else
  echo "mc not found on PATH; assuming bucket ${BUCKET} already exists" >&2
fi
