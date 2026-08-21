# DD-02 — Replication and ownership

**Status:** built
**Date:** 2026-08-21
**Decisions:** [ADR-08](../decisions/ADR-08-fence-by-shared-txid.md), [ADR-09](../decisions/ADR-09-snapshot-before-releasing-the-lease.md), [ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md), [ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md), [ADR-14](../decisions/ADR-14-bounded-read-staleness.md), [ADR-11](../decisions/ADR-11-simulate-the-protocol-only.md)

**Lands in:** `lib/ash_cell/lease.ex`, `lib/ash_cell/replicator.ex`, `lib/ash_cell/object_store.ex`,
`lib/ash_cell/snapshot_policy.ex`, `lib/ash_cell/ownership.ex`, `lib/ash_cell/manager.ex`

## What this is

How a cell survives a node dying: an object store holding leases, generation counters, and
whole-file snapshots, all coordinated with S3 conditional writes rather than a membership
protocol.

## What this proves

- Exactly one writer wins a contested cell — 12 concurrent claimants, one winner.
- A fenced writer cannot persist: its conditional PUT is refused, before it acknowledges
  anything to a caller.
- A destroyed database restores from the bucket.
- Revoking a key shreds one tenant only; the others are untouched.
- A dormant cell ships once and then stops paying the PUT cost.
- A killed node blocks its successor for the full lease TTL; a drained node does not.

## Why it needs a cell

The single-writer property this section fences is *the* thing a cell is: without it, "one
encrypted file" degrades to "one encrypted file two processes are racing to write." The object
store is the only shared state between otherwise-unconnected nodes — "no membership protocol, no
failure detector, no quorum" — so ownership has to be provable from conditional writes alone,
not inferred from liveness.

## Non-goals

- Not RPO=0. Litestream v0.5 is ~1s RPO, and periodic snapshotting here is coarser still —
  bounded by `wal_bytes` and `max_age_ms`, not continuous.
- Not page-level replication. Snapshots are whole files; cost scales with database size, not
  with change size.
- Not a fix for stale reads. Fencing here protects writes only (ADR-14).
- Not cross-cell coordination — every mechanism below is scoped to one cell.

## Data model

Per cell, three object-store objects, deliberately separate:

- **Lease** — one object, claimed by conditional write, carrying owner identity and expiry.
  Deleted on clean release.
- **Generation counter** — its own object, outliving the lease. Deriving it from the lease body
  was tried and rejected: `release/2` deletes the lease, so a derived counter restarted at 1 on
  every clean handoff, handing two successive owners the same generation (measured: 1 → 1;
  after the fix, 1 → 2).
- **Snapshot objects**, keyed by `AshCell.Replicator.snapshot_key/2` on transaction id, one
  namespace per cell shared by every owner past and present.

## Trade-offs

- **Txid-keyed durability writes, not generation-keyed** ([ADR-08](../decisions/ADR-08-fence-by-shared-txid.md)).
  Generation-keyed durability writes to a *different* key per owner, so a fenced writer's
  conditional PUT succeeds against its own generation's key and the write is silently
  superseded — "nothing is refused anywhere." Txid gives both the current and the displaced
  owner the same next key to contend for.
- **The high-water mark is read once, at adoption, and advanced locally thereafter.** Re-reading
  it before a write would let a fenced writer read its successor's mark and write safely past
  it — the locality *is* the mechanism, not an optimisation of it.
- **A store read failure fails the claim rather than defaulting to zero.** `latest_txid/2`
  returns `{:ok, 0}` only for a cell that has genuinely never shipped; any other read failure
  propagates. Collapsing the two would let a cell with fifty snapshots adopt a mark of 0 and
  reclaim already-used txids. The same defect shape was found and fixed in `next_generation/2`.
- **Whole-file snapshots on a jittered timer, not per-commit durability**
  ([ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md)). Per-commit segment
  shipping (celld's model) needs exqlite WAL-frame access that does not exist, and re-plumbs
  Ash's entire post-commit side-effect model. The chosen alternative reuses
  `Replicator.snapshot/3` unchanged and is enabled by default — "a durability feature nobody
  enabled protects nobody" — at the cost of scaling with file size rather than change size.
- **Dirty signal is WAL size on disk, not a write counter or dirty page count.** WAL size is one
  `File.stat` on the `-wal` sidecar and is closest to "how much would I lose"; a write counter
  conflates reads and writes; dirty page count is truer but not exposed by exqlite.
- **`PRAGMA wal_checkpoint(TRUNCATE)`, not `PASSIVE`, before snapshotting.** The difference
  between a dormant cell shipping once and then stopping, versus paying a whole-file PUT every
  tick forever, is this one word.
- **Fail-closed on a refused shipment** ([ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md)):
  quarantine plus force-close plus lease drop, together — either alone leaves a path back to
  serving a cell this node no longer owns.

## Measurements this must produce

- Fencing: fenced write returns `{:error, :precondition_failed}` after the txid fix (it returned
  `{:ok, etag}` before it).
- Generation continuity across a clean handoff: 1 → 2, not 1 → 1.
- Killed-node vs drained-node lockout: `{:held_by, "node-a"}` until TTL vs immediate claim.
  Demo run: "drained 3 cell(s) in 1ms; leases released."
- Test-speed cliff: an unreachable-endpoint fencing test took 13.1s (Req's retry defaults); the
  equivalent revoked/deleted-bucket scenario takes 0.1s through the same code path.

## Staging

1. Lease and generation-counter objects, conditional-write claim/release
   ([ADR-09](../decisions/ADR-09-snapshot-before-releasing-the-lease.md) groundwork).
2. Drain ordering fixed: seal → quiesce → checkpoint → snapshot → release → close, with release
   last so a successor never resumes from a stale snapshot while newer bytes sit only on the
   departing disk.
3. DST Stage 0 mutation testing built to find protocol defects by construction rather than by
   manual log-reading ([ADR-11](../decisions/ADR-11-simulate-the-protocol-only.md)) — it found
   the generation-vs-txid defect described above (`test/dst_stage0_test.exs:87` predicted it
   before the fix landed).
4. Txid-keyed fencing shipped, `test/fencing_test.exs` holding both the collision and the
   non-collision half.
5. Fail-closed-on-refusal added on top of the fencing fix.
6. Periodic snapshot-on-a-timer added last, closing the "kill -9 loses everything since
   activation" gap that drain alone did not.
7. Bounded read staleness (`AshCell.Ownership`) added, named explicitly as protecting reads
   only up to a TTL, not closing the read-fencing gap.

## Where it stops

- Fencing protects writes. A partitioned node keeps serving reads from a cell it no longer owns
  until its local lease TTL passes; `:strict` mode removes the window per-read at the cost of
  the performance argument, and is not the default.
- `ObjectStore.list/2` has no S3 pagination and breaks past 1000 snapshots.
- Snapshot and restore are non-atomic whole-file operations.
- The fake object-store model in the DST simulation encodes *believed* conditional-write
  semantics; a separate conformance run against real MinIO, R2 and Tigris is required because
  "S3-compatible" carries real weight in the correctness story.
- No cell-level DSL exists yet for snapshot cadence; it is a single fleet-wide supervisor
  option.

## Open risks

- SQLite's `synchronous` pragma is left at exqlite's default (`:normal`), which in WAL mode
  means a returned `COMMIT` is not necessarily fsynced — a possible silent loss on power loss
  or kernel panic that the DST simulation cannot see, since it models the object store, not
  fsync behaviour. No decision has been made and no measurement taken (ADR-20, open).
- `with_tenant/2` crashes with `MatchError` on documented error tuples.
- exqlite's nested savepoints share one fixed name; untested at depth ≥ 2, relevant to any
  future nested transaction inside a shipping/checkpoint sequence.
