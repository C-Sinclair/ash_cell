# ADR-09 — Snapshot before releasing the lease, and checkpoint before snapshotting

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-08](ADR-08-fence-by-shared-txid.md) · [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md) · [ADR-17](ADR-17-bind-per-liveview-callback.md)

## The decision

On drain, order the shutdown sequence as: seal the node, wait for bounded quiescence, then per
cell — checkpoint, snapshot, release lease, close. Release is last. Within that sequence,
checkpoint always precedes snapshot.

## Context

A cell deployment moves all its data every time it deploys. A killed node leaves leases nobody
released — locking successors out for a full TTL — plus local writes nobody shipped. Getting the
order of checkpoint, snapshot, release and close wrong either loses data silently or blocks
successors longer than necessary.

## Options considered

### Option A — release the lease immediately on shutdown

Frees a successor to claim the cell fastest. Cost: releasing before the snapshot ships opens a
window where a successor claims the cell and resumes from an older generation while newer data is
still only on the departing disk. This is "legitimate, correctly fenced, and silently lossy" —
fencing works exactly as designed and the data is still lost, because fencing prevents a torn
write, not a missed one.

### Option B (chosen) — checkpoint, snapshot, release, close, in that order

Ships the newest data before anything can claim the cell and start writing over it. Cost: a
successor is locked out for the full duration of the checkpoint and snapshot, not just the close.

## Decision and why

**Release is last because of what releasing early gives away.** Once the lease is released, a
successor is free to claim the cell and resume writing from whatever high-water mark it read at
adoption. If the departing node has not yet shipped its newest snapshot, that data is not
reachable by anyone — not torn, not corrupted, just gone, because nothing downstream of the
release ever looks at the departing node's disk again. Releasing after shipping closes that
window: by the time a successor can claim, the newest data is already durable somewhere fencing
can protect.

**Checkpoint is first because of what skipping it ships.** In WAL mode a committed row sits in the
`-wal` sidecar until folded into the main `.db` file. Copying the `.db` alone therefore ships a
database missing its most recent writes — proven by a test that reads the drained file with no
WAL sidecar and finds it stale. Checkpointing before snapshotting guarantees the file being copied
already contains everything committed.

**A failed drain keeps its lease** rather than releasing regardless, for the same reason release is
last: releasing on failure invites a successor to resume from an older generation while the newest
bytes are still only on the departing disk. Better to let the TTL expire while that data is still
recoverable on the original disk than to hand ownership to a successor that cannot see it.

Waiting for quiescence must be bounded, because waiting forever just trades an interrupted read for
a `SIGKILL` that loses the snapshot too — an unbounded wait does not actually protect anything, it
only delays the same failure mode.

## Consequences

- **What it rules out.** Any shutdown path that releases before shipping, including an
  optimisation to release early "since the data is probably fine."
- **What it makes worse.** Drain latency: a successor is locked out for checkpoint-plus-snapshot
  time, not just close time. A slow snapshot delays every successor's claim.
- **What stays open.** The bound on the quiescence wait is a policy choice with a real trade-off
  (interrupted reads vs. lost snapshots) that is not derived from a measurement here.
- **What now depends on it.** Quiescence tracking uses an ETS bind counter rather than a
  `GenServer.call`, to avoid a bottleneck in front of every tenanted query, since queries bypass
  the cell process and go straight to the repo instance. The counter must be floored at zero, and
  `restore/1` must decrement the tenant being *released*, not the one being restored to, or a
  nested `with_tenant` leaks count and stalls future drains. [ADR-08](ADR-08-fence-by-shared-txid.md)'s
  fencing depends on this ordering to guarantee the shipped snapshot is the newest one before a
  successor can claim. [ADR-17](ADR-17-bind-per-liveview-callback.md)'s holder tracking is what
  keeps a live LiveView session from being counted as quiescent between callbacks.

## Evidence

- Measured contrast: a killed node's successor gets `{:held_by, "node-a"}` and is locked out until
  TTL; a drained node's successor claims immediately. Demo run: "drained 3 cell(s) in 1ms; leases
  released."
- Checkpoint-before-snapshot proven by a test reading the drained file with no WAL sidecar.
- 24 new tests, 6 against real MinIO, including one asserting the killed-node behaviour "so the
  contrast is real rather than rhetorical". Suite 83 → 94.
- Commits: `09edf25`, superseded/extended by `cc8b248`.

## Notes

See [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md) for the periodic (non-drain) snapshot
path, which reuses `Replicator.snapshot/3` and required txid reservation to become atomic so a
periodic snapshot racing a drain is not handed the same txid.
