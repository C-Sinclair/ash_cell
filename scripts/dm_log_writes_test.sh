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
  # Already removed before the replay in the happy path; harmless if gone.
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

echo "==> releasing the device before reading its log"
# The log superblock is not readable while the dm target still holds the device,
# which is what "Magic doesn't match" means: the first attempt replayed before
# removing the target and read nothing. Remove it, keeping both loop devices.
dmsetup remove "$DM_NAME"

echo "==> replaying every flush boundary"

marks=$(replay-log --log "$LOG_LOOP" --list-marks 2>&1) || true

# A tier that verifies nothing must not report success. The first run of this
# script did exactly that: replay-log failed, the loop below never executed, and
# it printed a pass. Tiers 1 and 2 both guard against an empty trace and this one
# did not, which made it strictly worse than having no tier 3 at all -- a green
# check that means nothing is read as a guarantee.
if ! grep -qE '^[0-9]+' <<<"$marks"; then
  echo >&2
  echo "FAIL -- could not read any flush boundaries from the log device." >&2
  echo "replay-log said:" >&2
  echo "$marks" | sed 's/^/  /' >&2
  echo >&2
  echo "Nothing was verified. This is a harness failure, not a durability result." >&2
  exit 1
fi

boundaries=$(grep -cE '^[0-9]+' <<<"$marks")
echo "    $boundaries flush boundaries to replay"

failures=0
checked=0

while read -r mark; do
  [[ "$mark" =~ ^[0-9]+ ]] || continue
  mark="${mark%% *}"

  if ! replay-log --log "$LOG_LOOP" --replay "$DEV_LOOP" --end-mark "$mark" >/dev/null 2>&1; then
    echo "    FAIL: could not replay to mark $mark"
    failures=$((failures + 1))
    continue
  fi

  # A crash may lose recent commits. It may never leave a filesystem that fsck
  # rejects, so this is a failure rather than a skip.
  if ! fsck.ext4 -fn "$DEV_LOOP" >/dev/null 2>&1; then
    echo "    FAIL: filesystem inconsistent at mark $mark"
    failures=$((failures + 1))
    continue
  fi

  if ! mount "$DEV_LOOP" "$MNT" 2>/dev/null; then
    echo "    FAIL: fsck passed but the filesystem would not mount at mark $mark"
    failures=$((failures + 1))
    continue
  fi

  if ! MIX_ENV=test PROBE_CELL_DIR="$MNT/cells" PROBE_ACK_FILE="$PROBE_ACK_FILE" \
    mix run test/fault/dm_verify.exs; then
    echo "    FAIL: database unreadable or commits out of order at mark $mark"
    failures=$((failures + 1))
  fi

  checked=$((checked + 1))
  umount "$MNT"
done <<<"$marks"

if [[ $checked -eq 0 ]]; then
  echo >&2
  echo "FAIL -- $boundaries boundaries were listed but none could be checked." >&2
  echo "Nothing was verified; do not read this as a pass." >&2
  exit 1
fi

echo "    checked $checked boundaries"

echo
if [[ $failures -eq 0 ]]; then
  echo "==> $checked flush boundaries replayed to a consistent filesystem and an ordered database."
else
  echo "==> FAILED at $failures replay points." >&2
  exit 1
fi
