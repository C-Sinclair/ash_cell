#!/usr/bin/env bash
#
# Power-loss test for ADR-20: does a cell keep every commit it acknowledged?
#
# Killing a process cannot answer this, because the page cache outlives the process.
# This records every block write the cell's filesystem makes, through dm-log-writes,
# with a mark after each acknowledged commit. It then replays the log up to sampled
# marks onto a blank device. Each replay is the disk as a power cut at that moment
# would leave it. The test mounts each one and checks that SQLite opens the cell,
# passes `PRAGMA integrity_check`, and holds every row acknowledged before the mark.
#
# Linux only, needs root, the dm-log-writes kernel module, `replay-log`, and
# `sqlite3`. CI runs it; see the durability job.
#
#   scripts/power_loss/run.sh <synchronous> [commits] [sample_every]
#
# Exits nonzero if any sampled replay lost an acknowledged commit or failed the
# integrity check.
set -euo pipefail

SYNCHRONOUS="${1:?synchronous level: default, normal, full or extra}"
COMMITS="${2:-200}"
SAMPLE_EVERY="${3:-10}"
SIZE_MB="${POWER_LOSS_SIZE_MB:-256}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
DM_NAME="ashcell_lw_$$"
MOUNT="${WORK}/mnt"
DATA_LOOP=""
LOG_LOOP=""
REPLAY_LOOP=""

cleanup() {
  set +e
  mountpoint -q "${MOUNT}" && sudo umount "${MOUNT}"
  sudo dmsetup remove "${DM_NAME}" 2>/dev/null
  for loop in "${DATA_LOOP}" "${LOG_LOOP}" "${REPLAY_LOOP}"; do
    [ -n "${loop}" ] && sudo losetup -d "${loop}"
  done
  rm -rf "${WORK}"
}
trap cleanup EXIT

make_loop() {
  truncate -s "$1" "$2"
  sudo losetup --find --show "$2"
}

DATA_LOOP="$(make_loop "${SIZE_MB}M" "${WORK}/data.img")"
LOG_LOOP="$(make_loop "$((SIZE_MB * 4))M" "${WORK}/log.img")"
REPLAY_LOOP="$(make_loop "${SIZE_MB}M" "${WORK}/replay.img")"
mkdir -p "${MOUNT}"

sudo dmsetup create "${DM_NAME}" \
  --table "0 $(sudo blockdev --getsz "${DATA_LOOP}") log-writes ${DATA_LOOP} ${LOG_LOOP}"

sudo mkfs.ext4 -q "/dev/mapper/${DM_NAME}"
sudo dmsetup message "${DM_NAME}" 0 mark mkfs
sudo mount "/dev/mapper/${DM_NAME}" "${MOUNT}"
sudo chown "$(id -u):$(id -g)" "${MOUNT}"

(cd "${ROOT}" && MIX_ENV=test mix run scripts/power_loss/writer.exs \
  "${MOUNT}/cells" "${SYNCHRONOUS}" "${COMMITS}" "${DM_NAME}")

sudo umount "${MOUNT}"
sudo dmsetup remove "${DM_NAME}"

lost=0
corrupt=0
checked=0

for n in $(seq "${SAMPLE_EVERY}" "${SAMPLE_EVERY}" "${COMMITS}"); do
  sudo dd if=/dev/zero of="${REPLAY_LOOP}" bs=1M count="${SIZE_MB}" status=none
  sudo replay-log --log "${LOG_LOOP}" --replay "${REPLAY_LOOP}" --end-mark "ack_${n}"

  # A read-write mount replays the ext4 journal, as booting after the power cut would.
  sudo mount "${REPLAY_LOOP}" "${MOUNT}"
  db="$(sudo find "${MOUNT}/cells" -name '*.db' -print -quit 2>/dev/null || true)"

  if [ -z "${db}" ]; then
    rows=0
    integrity="no database file"
  else
    integrity="$(sudo sqlite3 "${db}" 'PRAGMA integrity_check;' 2>&1 | head -1)"
    rows="$(sudo sqlite3 "${db}" "SELECT count(*) FROM tenant_patients;" 2>/dev/null || echo 0)"
  fi

  sudo umount "${MOUNT}"
  checked=$((checked + 1))

  if [ "${integrity}" != "ok" ]; then
    corrupt=$((corrupt + 1))
    echo "ack_${n}: integrity check failed: ${integrity}"
  elif [ "${rows}" -lt "${n}" ]; then
    lost=$((lost + 1))
    echo "ack_${n}: ${rows} of ${n} acknowledged rows present, $((n - rows)) lost"
  else
    echo "ack_${n}: all ${n} acknowledged rows present"
  fi
done

echo
echo "synchronous=${SYNCHRONOUS}: ${checked} power cuts replayed, ${lost} lost acknowledged commits, ${corrupt} failed the integrity check"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "| \`${SYNCHRONOUS}\` | ${COMMITS} | ${checked} | ${lost} | ${corrupt} |" >>"${GITHUB_STEP_SUMMARY}"
fi

[ "${lost}" -eq 0 ] && [ "${corrupt}" -eq 0 ]
