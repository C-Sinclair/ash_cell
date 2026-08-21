# DD-04 — The read cache

**Status:** built
**Date:** 2026-08-21
**Decisions:** [ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md), [ADR-02](../decisions/ADR-02-bind-in-the-data-layer.md)
**Lands in:** `lib/ash_cell/read_cache.ex`, `lib/ash_cell/binder.ex`

## What this is

A `persistent_term` cache of named projections, published in commit order by the cell's own
writer, replacing the assumption that a wider connection pool would speed up reads.

## What this proves

- Widening a cell's connection pool does not improve read throughput, and materially worsens
  it on a realistic query.
- A cache invalidated by the cell's own single writer is sound, not merely fast, because there
  is exactly one process that can make the cached value stale.
- The cache cannot publish a value computed from an in-flight, uncommitted write.

## Why it needs a cell

The cache's correctness argument is the cell's, not a general caching trick. A cache in front
of a shared database is a correctness problem: nothing tells the cache when someone else wrote.
A cell has exactly one writer, and that writer is the same process asking the data layer to
bind — so invalidation is not a guess, it is something the binder can *know* rather than infer.
This only works because a cell is single-writer; it would not transfer to a shared table.

## Non-goals

- Not a general Ash query cache. What is cacheable is a named projection the application
  defines, not an arbitrary query — "you cannot transparently cache an arbitrary Ash query,
  only a named projection, and naming it is the application's job."
- Not multi-node. The cache is owner-local `persistent_term`; nothing here replicates it to
  other nodes.
- Not a declared `read_strategy` option on the resource — that enum was designed and
  deliberately not shipped (see Trade-offs).

## Data model

Nothing persisted. Per cell, an epoch counter and a set of named entries in `persistent_term`,
keyed by cell key and projection name. `AshCell.Binder` is the only writer of the epoch,
because it is the only place that sees every statement and already knows read from write via
the `:usage` argument added to the fork's `tenant_binder` seam
([ADR-02](../decisions/ADR-02-bind-in-the-data-layer.md)).

## Trade-offs

- **`pool_size: 1` stays; the cache lives above SQLite, not inside it**
  ([ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md)). Widening the pool was claimed as
  "the cheap 10x" before being measured with `scripts/read_pool_probe.exs` (32 concurrent
  readers, median of 5):

  | | Pointer read | Manifest resolve (join + filter, ~12 rows) |
  |---|---|---|
  | `pool_size: 1` | 17.0 µs | 34.1 µs |
  | `pool_size: 8` | 20.2 µs | 64.0 µs — 1.9× *slower* |
  | `:persistent_term` | 0.04 µs | — |

  Point reads are flat to noise; a realistic filtered join is materially worse under a wider
  pool, because per-query overhead dominates and extra connections on one file add contention
  rather than parallelism. The earlier claim was explicitly reversed: "I was wrong about the
  pool — it isn't a win at all." The win instead is roughly 400× on the pointer read and 850×
  on the manifest resolve, moving to `persistent_term`.
- **Writes bracket themselves twice, and the second bracket is the one that matters.**
  `begin_write/1` erases the cell's entries and bumps the epoch before the statement;
  `end_write/2` bumps again after commit. Without the second bump, a reader could build a
  projection from pre-commit state, publish while the write was still open, and have that stale
  entry survive the commit. Publishing is refused outright while a write is open. Writers are
  monitored so a crash mid-write cannot leave a stale entry publishable forever.
- **`AshCell.transaction/2` needed its own bracket, found by an integration test rather than by
  reasoning.** It opens its transaction below the data layer, so the binder's bracket was
  closing at the last statement rather than at the actual commit — "a gap wide enough for
  exactly the stale publish the design was built to prevent."
- **The `read_strategy` enum (`:owner`, `:cached`, `:replicated`, `:leased`) was designed and
  not shipped.** `:owner` (reads bind to the owner node, linearizable, no new failure mode) and
  `:cached` (this doc's mechanism, still owner-only, pure win over `:owner`) were built.
  `:replicated` (remote nodes cache via broadcast invalidation — fast everywhere, but not
  linearizable, staleness bounded by broadcast latency) and `:leased` (`:replicated` plus
  revoke-before-commit — linearizable everywhere, but a rollback cannot commit until every
  reader lease is revoked or expired, a genuinely new failure mode under partition) were
  designed but not built. The enum was dropped rather than shipped with half its values
  unimplemented, because "you can't transparently cache an arbitrary Ash query, only a named
  projection, and naming it is the application's job" — an enum implies transparency the
  mechanism does not have.
- **Read admission can be per-resource; replication topology cannot.** Whether staleness is
  acceptable is a property of the data (a channel pointer and an install-event log want
  opposite answers in the same app), so admission is resource-level. But "you cannot ship half
  a SQLite file" — replication topology is irreducibly per-cell. And the strictest resource in
  a cell sets the write cost for the whole cell, since a commit is per-file: if any resource in
  a cell were `:leased`, every write to that cell would pay the revoke round trip. This is why
  an observation stream must live in a different cell from the decision it observes.

## Measurements this must produce

- The pool-widening probe above (already run; `pool_size: 1` vs `8` vs `persistent_term`,
  median of 5, 32 concurrent readers).
- 15 unit tests for the write-bracket ordering rules, 9 integration tests confirming an
  ordinary Ash write invalidates the cache (atomic update, bulk create, `Ash.count`).

## Staging

1. `scripts/read_pool_probe.exs` written and run first, to settle whether pool widening was
   worth building before building it.
2. `AshCell.ReadCache` built directly on the probe's result: `persistent_term`, epoch-bracketed
   writes, refuse-to-publish-while-open.
3. `AshCell.transaction/2`'s missing bracket found and fixed by an integration test, and the
   `read_strategy` enum removed in the same pass once it was clear only two of its four values
   existed.

## Where it stops

- No cross-node cache. `:replicated` and `:leased` remain designs, not code; nothing here makes
  a read fast on any node but the owner.
- No transparent query caching — every cached value is a projection the application named and
  wrote the recomputation function for.
- Read admission policy (per-resource) exists as a stated rule, not as DSL or enforced
  configuration — nothing in the shipped code prevents mixing consistency requirements inside
  one cell today; it is a design rule to be honoured, not a guard that raises.

## Open risks

- Fencing protects writes, not reads (ADR-14, described in DD-02); the read cache inherits that
  gap unchanged — a partitioned owner node can keep serving a locally-fresh but globally-stale
  cached projection past the point where it has lost the cell.
- If `:replicated` or `:leased` are ever built, the "strictest resource sets the whole cell's
  write cost" coupling becomes an operational constraint that has not yet been tested under
  load.
