# ADR-12 — Ship whole-file snapshots on a jittered schedule; defer per-commit durability

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · [ADR-08](ADR-08-fence-by-shared-txid.md) ·
[ADR-09](ADR-09-snapshot-before-releasing-the-lease.md) · [ADR-19](ADR-19-the-cell-cut-is-a-choice.md)

## The decision

Ship durability by periodic checkpoint-and-snapshot on a jittered timer, reusing
`Replicator.snapshot/3` unchanged, and defer per-commit durability as a separate research track.
The snapshotter is enabled by default. Before this change, `Replicator.snapshot/3` was called
only from `AshCell.Drain` (`lib/ash_cell/drain.ex:129`), so a `kill -9` lost everything written
since the cell activated — not an RPO at all.

## Context

A cell with no durability path between activation and drain has no RPO. Litestream v0.5 gives
~1s RPO, not RPO=0, and already uses S3 conditional writes as a lease — a second, independent
fencing mechanism that would disagree with AshCell's own. The forcing question was which
replication path to build, given the design's stated shape of one machine and a bucket, no
membership protocol, no failure detector, no quorum.

## Options considered

### Option A — Litestream sidecar

~1s RPO for free, no NIF work. Rejected: it creates two disagreeing fencing mechanisms —
Litestream's time-based S3 lease versus AshCell's `If-None-Match` generation claim — "a genuine
correctness hazard, not a tidiness complaint."

### Option B — In-BEAM WAL tailing, ack-gated

Keeps fencing in one place, but needs exqlite NIF work exqlite does not support — no
`wal_hook`, no commit hook, no session extension, no backup API. It would also require
re-plumbing Ash's entire side-effect model (notifiers, LiveView diffs, PubSub, Oban enqueues)
into a post-ack phase, since SQLite has no uncommit and a fenced writer must guarantee no
observer ever saw the transaction. Deliberately deferred as a separate research track.

Cost arithmetic, from celld's own published numbers (not a measurement of ours), for a
Discord-shaped workload: per-commit segment PUTs run ~46k PUT/s ≈ **$600k/month** before
storage; buffered behind a shared log, ~300 PUT/s ≈ **$4k/month**. Per-commit segment PUTs are
never viable at scale, independent of the side-effect problem. celld's own figures: writes
~5ms vs ~50ms S3 round trip; their published durable write is ~90ms.

### Option C — celld 0.3.0's peer-replicated write-behind log (fourth path)

RPO=0 via a 3-disk fleet quorum, S3 as async archive. Structurally it fits: single writer per
cell gives unambiguous commit order, and if the durability wait sits inside the fork's
`transaction/4` commit, the pre-ack side-effect problem largely dissolves, because Ash already
fires notifications post-commit. Rejected anyway: it needs ≥3 nodes with durable local disk
across AZs plus a membership/quorum protocol — trading away the design's most distinctive
property, per `AshCell.Lease`'s own docstring: "no membership protocol, no failure detector, no
quorum, and no need for the nodes to know that the other exists." One machine and a bucket
stops being valid. Left explicitly open: whether abandoning "correctness rests on conditional
writes, so clock skew never matters" is a price worth paying.

### Option D — periodic checkpoint-and-snapshot on a timer (chosen)

Reuses `Replicator.snapshot/3` unchanged. O(file size) per tick, so it does not scale
indefinitely, but is measurable and closed most of the gap for about a day's work.

## Decision and why

Chose Option D. It is the only path that ships without new fencing semantics, new NIF work, or
new infrastructure, and it directly replaces the previous state of "no snapshot until drain" —
an unbounded RPO — with a bounded, configurable one. Options A through C each solve more of the
durability problem but at a cost this design is not ready to pay yet: A conflicts with the
fencing model, B needs exqlite capabilities that do not exist, C gives up the single-node
premise entirely.

The dirty signal that triggers a tick was chosen from three candidates: writes since last
snapshot (nearly free via the existing query counter, but conflates reads and writes); dirty
page count (the truest signal, but not exposed by exqlite); and **WAL size on disk** via one
`File.stat` on the `-wal` sidecar — "closest to how much would I lose" — which was chosen as
primary. `wal_bytes` is backed by `max_age_ms` to catch low-traffic tenants. Configuration
shape: `{AshCell, store: store, snapshot: [wal_bytes: 4_000_000, max_age_ms: 60_000]}`. The
interval is jittered with a random first-tick offset so a fleet does not ship in lockstep.

The snapshotter is **enabled by default**, despite the behaviour change and the periodic
whole-file PUT cost per active cell it introduces: "a durability feature nobody enabled
protects nobody."

No cell-level DSL was added for cadence. Alternatives weighed: a fleet-wide supervisor option
(chosen — one knob, no new abstraction, immediately measurable; `AshCell.Supervisor` already
takes runtime `opts` passed to `Manager`/`Drain` at `supervisor.ex:9-17`); a per-tenant resolver
override (tenants are not known at compile time, and this really argues cadence should be
*adaptive*, which is what was built); a `cell do ... end` Spark DSL section (justified only once
several co-varying cell-level properties exist — cadence, key source, eviction timeout,
ownership check level; "a DSL wrapping one integer is ceremony"). `AshCell.Resource` is the
wrong altitude entirely, since many resources share one cell and putting cadence there lets them
disagree.

## Consequences

- **What it rules out.** Sub-second RPO. A tenant can still lose everything written since the
  last tick if the node dies between ticks.
- **What it makes worse.** Every active cell now pays a periodic whole-file PUT. Whole-file
  snapshotting is honest but not the production shape, and is noted as such in the module docs
  — cost scales with database size, not change size.
- **What stays open.** Per-commit durability (Path B) and quorum-based RPO=0 (the fourth path)
  are both deferred, not ruled out permanently. Whether clock skew's irrelevance is worth
  trading away for RPO=0 is an explicit open question.
- **What now depends on it.** `Replicator.ship/2` is now the single path for both the timer and
  the drain — txid reservation had to become atomic so a periodic snapshot racing a drain
  cannot be handed the same txid, since the loser's refused PUT would otherwise be
  indistinguishable from being fenced by another node. Because snapshots are whole files,
  re-reading the high-water mark mid-write (see [ADR-08](ADR-08-fence-by-shared-txid.md)) would
  be catastrophic rather than merely wrong.

## Evidence

- Checkpoint subtlety pinned by a test: the guarantee "a dormant cell ships once then stops"
  depends on `checkpoint` using `PRAGMA wal_checkpoint(TRUNCATE)` rather than `PASSIVE`. One
  word away from silently paying a whole-file PUT every tick forever on idle cells.
- Prior call site: `lib/ash_cell/drain.ex:129` was the only caller of `Replicator.snapshot/3`
  before this change.
- Commits: `9294ebf`, `302ecff`, `0498e7d`.
- Suite: 207 tests green, stable across 3 runs.
- Path B cost figures and the ~5ms/~50ms/~90ms numbers are celld's own published numbers, not
  measured here.
- Not verified: throughput and cost under a real fleet-scale workload; the snapshotter has been
  measured for correctness, not for cost at scale.

## Notes

The fourth path (celld 0.3.0 peer-replicated write-behind log) is the most likely candidate for
a future RPO=0 revisit, if the "one machine and a bucket" premise is ever renegotiated. See
[ADR-19](ADR-19-the-cell-cut-is-a-choice.md) for how windowing bounds the same whole-file cost
from the other direction, by shrinking the file rather than shipping it faster.
