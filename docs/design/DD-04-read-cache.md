# DD-04 — The read cache

**Status:** built; the store beneath it is being changed — see *The store, measured after the
fact* below
**Date:** 2026-08-21
**Decisions:** [ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md), [ADR-02](../decisions/ADR-02-bind-in-the-data-layer.md)
**Lands in:** `lib/ash_cell/read_cache.ex`, `lib/ash_cell/binder.ex`

## What this is

A cache of named projections, published in commit order by the cell's own writer, replacing the
assumption that a wider connection pool would speed up reads.

It was built on `persistent_term`, which was chosen on read cost with the invalidation cost
unmeasured. That measurement has since been taken and the default is moving to ETS with
exact-key deletes, `persistent_term` staying available per projection
([ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md)). The shipped code has not moved yet.

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
- Not multi-node. The cache is owner-local whichever store it uses; nothing here replicates it
  to other nodes.
- Not a declared `read_strategy` option on the resource — that enum was designed and
  deliberately not shipped (see Trade-offs). The per-projection *store* option is not that enum
  returning: it decides where a local value lives, not who may read it or with what
  consistency.
- Not a way to make invalidation cheaper by making it approximate. Every option here invalidates
  exactly; they differ only in what the invalidation costs.

## Data model

Nothing persisted. Per cell, an epoch counter and a set of named entries keyed by cell key and
projection name. `AshCell.Binder` is the only writer of the epoch, because it is the only place
that sees every statement and already knows read from write via the `:usage` argument added to
the fork's `tenant_binder` seam
([ADR-02](../decisions/ADR-02-bind-in-the-data-layer.md)).

Moving to exact-key deletes adds one thing to that state: the set of projection names each cell
has actually published. Invalidation has to erase what exists without being told what that is,
and today `bump/1` answers that by scanning instead — which is the cost being removed.

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
- **The store, measured after the fact.** `persistent_term` reads are a pointer into a literal
  area shared by the whole VM — no lock, no copy — and that is why it was chosen. Erasing one
  makes the VM find every process that may reference the dying area and copy the value onto its
  heap first, so an invalidation is priced by the size of the *node*, not of the cell.
  `scripts/read_cache_store_probe.exs` (OTP 28, 10 schedulers, median of 5) puts numbers on both
  halves. Reads, 32 concurrent readers × 500 reads:

  | Projection | `:persistent_term` | ETS |
  |---|---|---|
  | pointer, 4 words | 0.054 µs | **0.047 µs** |
  | manifest, 278 words | **0.049 µs** | 0.795 µs |
  | large, 3,850 words | **0.043 µs** | 5.119 µs |

  So the read advantage is the copy ETS makes, which means it does not exist at all for a small
  projection — including the pointer the original probe measured — and grows with a large one.

  Invalidation, as CPU busy across all schedulers with an identical-barrier ETS run subtracted
  (the cleanup is scheduled, so it never appears in the caller's wall clock):

  | Processes holding a reference | `:persistent_term` | ETS |
  |---|---|---|
  | 0 | 622 µs | 13 µs |
  | 100 | 3.01 ms | — |
  | 1,000 | 14.62 ms | — |
  | 10,000 | 71.77 ms | — |

  622 µs with *no* holders is what decides it: the scan is priced by the process table, not by a
  projection's readers. And the bracket runs for every write to every cell whether or not that
  cell has ever cached anything — so a fleet where one demo uses the cache has every app paying
  for it.
- **A naive ETS port is worse than what exists.** 500 sequential brackets on an empty cache:
  `ReadCache.writing/2` 3.37 ms, ETS via `match_delete` 17.4 ms, ETS by exact key 125 µs.
  `:ets.match_delete/2` with a partially bound key is a whole-table operation, and pairing it
  with `write_concurrency` makes every bucket lock part of the price — 36 µs a bracket. The win
  is exact-key deletes or nothing.
- **The store is a keyword on a call, not a declaration.** The application already names the
  projection when it calls `read/3`, so the store rides along on that call and needs no DSL.
  Its sharp edge has to be documented where it is chosen rather than only in the ADR:
  `persistent_term`'s cost is global, so one projection opting in slows every other cell's
  writes on that node.
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
- The store comparison above (already run; `scripts/read_cache_store_probe.exs`), covering read
  cost by projection size, invalidation by reference-holder count, the `bump/1` walk by table
  size, and the write bracket end to end.
- Still owed, when the store change is written: the same bracket numbers taken through the real
  `AshCell.Binder` path rather than the probe's stand-in, and a demonstration that the ordering
  tests above pass unchanged under both stores. The ordering rules are the part that must not
  move.

## Staging

1. `scripts/read_pool_probe.exs` written and run first, to settle whether pool widening was
   worth building before building it.
2. `AshCell.ReadCache` built directly on the probe's result: `persistent_term`, epoch-bracketed
   writes, refuse-to-publish-while-open.
3. `AshCell.transaction/2`'s missing bracket found and fixed by an integration test, and the
   `read_strategy` enum removed in the same pass once it was clear only two of its four values
   existed.
4. `scripts/read_cache_store_probe.exs` written to measure the invalidation half, which the
   first probe never asked about. Three earlier versions of its invalidation section measured
   the instrument rather than the cleanup — a busy-loop sampler starving the schedulers, holders
   that stopped referencing the term after the first erase, and a barrier costing more than the
   work it was making observable — and were discarded. The surviving section prints `swamped`
   where the difference is inside its own noise rather than reporting a number.
5. Not yet done: ETS with exact-key deletes as the default, published-name tracking to make that
   possible, and `store:` on `read/3`.

## Where it stops

- No cross-node cache. `:replicated` and `:leased` remain designs, not code; nothing here makes
  a read fast on any node but the owner.
- No transparent query caching — every cached value is a projection the application named and
  wrote the recomputation function for.
- The store decision is recorded and unimplemented. Everything shipped today is
  `persistent_term`, including the node-wide invalidation cost, and every app pays it while only
  `demos/rollout` reads the cache.
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
