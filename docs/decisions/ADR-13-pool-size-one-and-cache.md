# ADR-13 — Keep `pool_size` at 1 and cache above SQLite instead

**Status:** corrects an earlier belief
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · [ADR-02](ADR-02-bind-in-the-data-layer.md) ·
[ADR-19](ADR-19-the-cell-cut-is-a-choice.md)

## The decision

Keep `pool_size: 1` in `cell.ex` — no library change — and get the read win from a
`persistent_term` cache in `AshCell.Binder` instead. This reverses an earlier belief that
widening the pool was "the cheap 10x": measured, it is flat to noise on point reads and
materially worse on a realistic filtered join.

## Context

Reads for one cell serialise behind each other at `pool_size: 1`. Widening the pool looked like
the obvious fix and was claimed as "the cheap 10x" before being measured. The forcing event was
running that measurement.

## Options considered

### Option A — widen `pool_size`

What it was expected to buy: parallel reads on one cell. What it actually cost, measured with
`ash_cell/scripts/read_pool_probe.exs`, one file, 32 concurrent readers, median of 5:

| | Pointer read | Manifest resolve (join + filter, ~12 rows) |
|---|---|---|
| `pool_size: 1` | 17.0 µs | 34.1 µs |
| `pool_size: 8` | 20.2 µs | 64.0 µs — 1.9× *slower* |
| `:persistent_term` | 0.04 µs | — |

Point reads are flat to noise; a realistic filtered join is materially worse under a wider
pool. "Per-query overhead dominates, and extra connections on one file add contention rather
than parallelism." Lost: "I was wrong about the pool — it isn't a win at all."

### Option B — `persistent_term` cache above SQLite (chosen)

~400× faster on the pointer read, ~850× on the manifest resolve, measured against
`pool_size: 1` in the same probe. Costs correctness machinery: invalidation has to be exact,
not approximate, because a cell has exactly one writer and this node is it — so invalidation is
not a guess, unlike a cache in front of a shared database. "Which is the argument the whole
thing rests on."

### Option C — a four-way `read_strategy` enum (designed, not shipped)

Four strategies were named: `:owner` (reads bind to the owner node; linearizable, no new
failure mode — "the honest default"); `:cached` (owner-local `persistent_term` published after
commit; still owner-only, removes SQLite from the read path; "pure win over `:owner`");
`:replicated` (remote nodes cache via broadcast invalidation; fast everywhere but **not
linearizable**, staleness bounded by broadcast latency); `:leased` (`:replicated` plus
revoke-before-commit; linearizable everywhere, but a rollback cannot commit until every reader
lease is revoked or expired, so a rollback blocks if a reader node is unreachable — a genuinely
new failure mode under partition). Only `:owner` and `:cached` were built. The enum was dropped
because "you can't transparently cache an arbitrary Ash query, only a named projection, and
naming it is the application's job" — shipping it would have been "a declaration with nothing
behind half its values."

## Decision and why

The pool measurement settled Option A outright: extra connections on one SQLite file add
contention, not parallelism, so widening the pool is not a lever worth pulling. The
`persistent_term` cache (Option B) delivers the actual win, and it is safe specifically because
a cell has one writer and this node is it — cache invalidation is exact, not heuristic. The
cache lives in `AshCell.Binder`, the only place that sees every statement, and which knows read
from write via [ADR-02](ADR-02-bind-in-the-data-layer.md)'s `:usage` argument — this is what
made the cache possible at all.

The four-way enum (Option C) was designed in full but only half of it — `:owner` and
`:cached` — was ever buildable without the application naming what is being cached. Rather than
ship a declaration with unimplemented values, the enum was removed entirely.

Two rules fell out of that design work and are load-bearing even though the enum itself was
not shipped:

- **Read admission can be per-resource,** because whether staleness is acceptable is a property
  of the data, not the deployment — a channel pointer and an install-event log want opposite
  answers in the same app.
- **Replication topology is irreducibly per-cell:** "you cannot ship half a SQLite file." And
  **the strictest resource in a cell sets the write cost for the whole cell**, since a commit is
  per-file — so if any resource in a cell is `:leased`, every write to that cell pays the revoke
  round trip. This is why an observation stream must live in a different cell from the decision
  it observes: "separate the decision cell from the observation stream."

## Consequences

- **What it rules out.** Widening `pool_size` as a lever for read throughput on one cell — it
  does not help and measurably hurts joins.
- **What it makes worse.** Cache correctness now depends on exact bracketing of every write
  path, including transactions, which is more machinery than "just add connections" would have
  needed if it had worked.
- **What stays open.** `:replicated` and `:leased` remain designed but unbuilt. Multi-node reads
  of a cell are not addressed by this ADR.
- **What now depends on it.** `AshCell.Binder`'s epoch bracket: writes **erase and bump the
  epoch before the statement and again after commit**. The second bump is the one that matters
  — without it a reader could build a projection from pre-commit state, publish while the write
  is still open, and have that stale entry survive the commit. Publishing is refused outright
  while a write is open. Writers are monitored, so a crash mid-write cannot leave a stale entry
  publishable forever. Readers repopulate lock-free via compare-and-set on the epoch.

A bug was found by an integration test, not by reasoning: `AshCell.transaction/2` opens its
transaction *below* the data layer, so the binder's bracket closed at the last statement rather
than at the actual commit — "a gap wide enough for exactly the stale publish the design was
built to prevent." Fixed with its own bracket.

## Evidence

- Probe: `ash_cell/scripts/read_pool_probe.exs`, 32 concurrent readers, median of 5.
- 15 unit tests for the ordering rules; 9 integration tests (ordinary Ash write invalidates the
  cache, including atomic update, bulk create, `Ash.count`).
- Commits: `757ec65` (probe), `dd74da3` (cache), `ad3ac3c` (transaction bracket + enum removal).
- Not verified: cache behaviour across multiple nodes reading the same cell (not applicable —
  `:owner`/`:cached` are both owner-local by design).

## Notes

If `:replicated` or `:leased` is ever revisited, the per-cell write-cost rule above should be
the first thing checked against the target workload, since it determines whether adding a
lenient resource to a strict cell is safe.
