#!/usr/bin/env bash
#
# ADR-20 tier 3: the same durability question, asked at the block layer.
#
# Tiers 1 and 2 both observe the process. They see what it asked the kernel for,
# which is enough to catch a missing or misplaced barrier, and is what makes them
# runnable without privileges. What they cannot see is the layer where the
# remaining lies live:
#
#   * a filesystem reordering writes between barriers, reaching an on-disk state
#     that is not a prefix of the issue order -- tier 2's crash model assumes it
#     is one, and that assumption is exactly what this checks
#   * a write that reached the page cache but never the device
#
# dm-log-writes sits under the filesystem and records every bio with its flush
# and FUA flags, so `replay-log` can reconstruct the device as it would have been
# at any flush boundary. That is a real power-failure model rather than an
# approximation of one.
#
# Needs root, loop devices and the dm-log-writes module, which is why it is CI
# only: Docker Desktop's linuxkit kernel has neither dm_log_writes nor dm_flakey
# and no modprobe, so this cannot run on a developer machine at all. Tiers 1 and
# 2 are the ones that run locally.
#
#     sudo scripts/dm_log_writes_test.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "tier 3 is Linux only; run scripts/barrier_test.sh for tiers 1 and 2" >&2
  exit 2
fi

if [[ "$(id -u)" != "0" ]]; then
  echo "tier 3 needs root for loop devices and device-mapper" >&2
  exit 2
fi

WORK="${TMPDIR:-/tmp}/ash_cell_dm"
DEV_IMG="$WORK/data.img"
LOG_IMG="$WORK/log.img"
MNT="$WORK/mnt"
DM_NAME="ashcell-logwrites"
# Kept off the logged device on purpose: a record of what was acknowledged is
# useless if it can be replayed away along with the thing it describes.
export PROBE_ACK_FILE="$WORK/acknowledged.txt"

cleanup() {
  set +e
  umount "$MNT" 2>/dev/null
  dmsetup remove "$DM_NAME" 2>/dev/null
  [[ -n "${DEV_LOOP:-}" ]] && losetup -d "$DEV_LOOP" 2>/dev/null
  [[ -n "${LOG_LOOP:-}" ]] && losetup -d "$LOG_LOOP" 2>/dev/null
}
trap cleanup EXIT

echo "==> preparing"
rm -rf "$WORK"
mkdir -p "$MNT"

# The log grows with total write volume, not with the data size, so it is the
# larger of the two by a wide margin. A log that fills mid-run does not fail
# loudly -- it silently stops recording, and every replay after that point is a
# state the machine was never in.
truncate -s 512M "$DEV_IMG"
truncate -s 2G "$LOG_IMG"

if ! modprobe dm-log-writes 2>/dev/null && [[ ! -d /sys/module/dm_log_writes ]]; then
  echo "dm-log-writes is not available in this kernel ($(uname -r))." >&2
  echo "On Ubuntu it lives in linux-modules-extra-\$(uname -r)." >&2
  exit 2
fi

DEV_LOOP=$(losetup --find --show "$DEV_IMG")
LOG_LOOP=$(losetup --find --show "$LOG_IMG")

SECTORS=$(blockdev --getsz "$DEV_LOOP")
dmsetup create "$DM_NAME" --table "0 $SECTORS log-writes $DEV_LOOP $LOG_LOOP"

echo "==> building replay-log"
# Only the log-writes tool is needed, not the whole of xfstests, and building it
# alone avoids pulling in that suite's considerable build dependencies.
if ! command -v replay-log >/dev/null; then
  git clone --depth 1 https://git.kernel.org/pub/scm/fs/xfs/xfstests-dev.git "$WORK/xfstests" 2>/dev/null
  gcc -O2 -o /usr/local/bin/replay-log \
    "$WORK"/xfstests/src/log-writes/*.c -I"$WORK/xfstests/src/log-writes"
fi

echo "==> running the workload on the logged device"
mkfs.ext4 -q -F "/dev/mapper/$DM_NAME"
mount "/dev/mapper/$DM_NAME" "$MNT"

CELLS="$MNT/cells"
mkdir -p "$CELLS"

MIX_ENV=test PROBE_CELL_DIR="$CELLS" PROBE_SYNC="${PROBE_SYNC:-full}" \
  PROBE_ACK_FILE="$PROBE_ACK_FILE" mix run test/fault/dm_workload.exs

umount "$MNT"

echo "==> replaying every flush boundary"
# --check fua replays to each FUA/flush boundary rather than to every bio, which
# is the set of states a device can actually be caught in. Every one of them must
# mount and fsck clean: a crash may lose recent commits, it may never leave a
# filesystem or a database that cannot be read.
failures=0
entries=$(replay-log --log "$LOG_LOOP" --replay "$DEV_LOOP" --check fua --num 0 2>&1 | tail -1 || true)
echo "    log entries: $entries"

while read -r mark; do
  [[ -z "$mark" ]] && continue

  replay-log --log "$LOG_LOOP" --replay "$DEV_LOOP" --end-mark "$mark" >/dev/null 2>&1 || continue

  if ! fsck.ext4 -fn "$DEV_LOOP" >/dev/null 2>&1; then
    echo "    FAIL: filesystem inconsistent at mark $mark"
    failures=$((failures + 1))
    continue
  fi

  mount "$DEV_LOOP" "$MNT" 2>/dev/null || continue

  if ! MIX_ENV=test PROBE_CELL_DIR="$MNT/cells" PROBE_ACK_FILE="$PROBE_ACK_FILE" \
    mix run test/fault/dm_verify.exs; then
    echo "    FAIL: database unreadable or lost an acknowledged commit at mark $mark"
    failures=$((failures + 1))
  fi

  umount "$MNT"
done < <(replay-log --log "$LOG_LOOP" --list-marks 2>/dev/null || true)

echo
if [[ $failures -eq 0 ]]; then
  echo "==> every flush boundary replayed to a consistent filesystem and a readable database."
else
  echo "==> FAILED at $failures replay points." >&2
  exit 1
fi
