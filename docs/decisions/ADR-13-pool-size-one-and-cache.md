# ADR-13 — Keep `pool_size` at 1 and cache above SQLite instead

**Status:** corrects an earlier belief
**Last changed:** 2026-08-21 — the *store* beneath the cache is now measured rather than
assumed. `:persistent_term` was chosen on read cost alone; invalidation cost was never
measured. It is measured now, and the default changes to ETS.
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · [ADR-02](ADR-02-bind-in-the-data-layer.md) ·
[ADR-19](ADR-19-the-cell-cut-is-a-choice.md)

## The decision

Keep `pool_size: 1` in `cell.ex` — no library change — and get the read win from a cache in
`AshCell.Binder` instead. This reverses an earlier belief that widening the pool was "the cheap
10x": measured, it is flat to noise on point reads and materially worse on a realistic filtered
join.

Beneath that cache, **store projections in ETS and delete them by exact key**, with
`:persistent_term` available per projection for values that change at deploy rate.
`:persistent_term` was the original choice and it was made on read cost alone; its invalidation
cost is borne by the whole node, not by the cell being invalidated, and at fleet write rates
that is the larger number. **This part is decided and not yet implemented** — the code still
uses `:persistent_term` unconditionally.

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

### Option D — `:persistent_term` for every projection (what was built)

Chosen originally on the strength of the read number above, which is real: a read is a pointer
into a literal area shared by the whole VM, with no lock and no copy. What was never measured is
what it costs to invalidate one. Erasing or replacing a term makes the VM find every process
that may reference the dying literal area and copy the value onto its heap before the area can
be freed, so the cost is priced by the size of the *node* and not by the cell being invalidated.

Measured with `ash_cell/scripts/read_cache_store_probe.exs` (OTP 28, 10 schedulers, median of 5,
one publish-and-erase per round). The figure is CPU busy across all schedulers, with an ETS run
doing an identical barrier subtracted, because the cleanup is scheduled rather than synchronous
and never appears in the caller's wall clock:

| Processes holding a reference | `:persistent_term` | ETS |
|---|---|---|
| 0 | 622 µs | 13 µs |
| 100 | 3.01 ms | — |
| 1,000 | 14.62 ms | — |
| 10,000 | 71.77 ms | — |

**622 µs with nobody holding a reference at all** is the finding that decides it. The scan is not
priced by the readers a projection has; it is priced by the process table. A fleet of 10,000
cells each written once a minute is 167 writes a second, and `AshCell.Binder` brackets every
write twice, so that is ~330 invalidations a second, each one a node-wide pass.

Read cost, same probe, 32 concurrent readers × 500 reads:

| Projection | `:persistent_term` | ETS |
|---|---|---|
| pointer, 4 words | 0.054 µs | **0.047 µs** |
| manifest, 278 words | **0.049 µs** | 0.795 µs |
| large, 3,850 words | **0.043 µs** | 5.119 µs |

Which reframes the read advantage as well: it is entirely the copy ETS makes, so it does not
exist for a small projection and grows with a large one. On a bare pointer — the very shape the
original probe measured — the two are indistinguishable.

### Option E — ETS by exact key, `:persistent_term` per projection (chosen)

A naive port to ETS is *worse* than what is there today, which is the trap in this option and
the reason it needed measuring rather than reasoning about. Same probe, 500 sequential brackets
on an empty cache — the common case, since most cells in a fleet publish no projection and pay
the bracket anyway:

| Bracket | 500 sequential | 32 concurrent |
|---|---|---|
| `ReadCache.writing/2` as built | 3.37 ms | 2.15 ms |
| ETS, `match_delete` | 17.4 ms | 3.29 ms |
| ETS, delete by exact key | **125 µs** | **169 µs** |

`:ets.match_delete/2` with a partially bound key is a whole-table operation, and on a
`write_concurrency` table it has to take every bucket lock — that pairing measured 36 µs per
bracket. Deleting by exact key is 27× faster than today's path, and it requires the cache to
track which projections each cell has published, which it does not do today.

That tracking is what makes the per-projection store possible at all: the invalidation side has
to erase whatever exists without being told, so it must know what a cell published and where.

Also measured, and the reason `bump/1` changes regardless of which store wins: it finds a cell's
entries by walking `:persistent_term.get()`, the whole VM-wide table, shared with every
dependency.

| Table size | walk, as `bump/1` does | ETS `match_delete` |
|---|---|---|
| 10 | 1 µs | 1 µs |
| 100 | 6 µs | 5 µs |
| 1,000 | 123 µs | 51 µs |
| 10,000 | 2.15 ms | 585 µs |

## Decision and why

The pool measurement settled Option A outright: extra connections on one SQLite file add
contention, not parallelism, so widening the pool is not a lever worth pulling. The
`persistent_term` cache (Option B) delivers the actual win, and it is safe specifically because
a cell has one writer and this node is it — cache invalidation is exact, not heuristic. The
cache lives in `AshCell.Binder`, the only place that sees every statement, and which knows read
from write via [ADR-02](ADR-02-bind-in-the-data-layer.md)'s `:usage` argument — this is what
made the cache possible at all.

Between Options D and E: ETS by exact key, because the read advantage `:persistent_term` was
chosen for turns out to be conditional on the projection being large, while its invalidation
cost is unconditional and borne by the whole node. `:persistent_term` stays available for a
projection whose invalidation genuinely is a deploy — a release pointer written twice a week and
read by every device is exactly that — because there the read number is free and the write
number never arrives.

**Two values, and they are not the old enum's survivors.** `:ets` and `:persistent_term` answer
"where does this local value live", not "who may read it and with what consistency". Both are
owner-local, both are invalidated by the same bracket under the same epoch rules, and neither
changes what a reader is promised. That is what makes it a storage detail on a call the
application already writes, rather than a declaration about arbitrary queries — which is
precisely what sank Option C. Nothing about it needs a DSL: the application already names the
projection at the call site, so the store rides along as a keyword on that call.

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
  does not help and measurably hurts joins. Also `:ets.match_delete/2` as the invalidation
  mechanism: it is a table scan, and pairing it with `write_concurrency` is worse still.
- **What it makes better.** A fleet that caches nothing stops paying a node-wide scan for every
  write. Four of the five demos are in that position today: only `rollout` reads the cache, and
  every app pays its invalidation.
- **What it makes worse.** Cache correctness now depends on exact bracketing of every write
  path, including transactions, which is more machinery than "just add connections" would have
  needed if it had worked.
- **What stays open.** `:replicated` and `:leased` remain designed but unbuilt. Multi-node reads
  of a cell are not addressed by this ADR. The ETS default and the per-projection store option
  are decided here and not yet written.
- **What is unusual about the option, and must stay documented next to it.**
  `:persistent_term`'s cost is global. One projection opting in makes every *other* cell's
  writes on that node slower, because the scan does not care whose term it was. A per-projection
  option with a node-wide consequence is a sharp edge, and the docs have to say so where the
  option is chosen rather than only here.
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
- Probe: `ash_cell/scripts/read_cache_store_probe.exs`, OTP 28, 10 schedulers, median of 5 —
  read cost by projection size, invalidation by reference-holder count, the `bump/1` walk, and
  the write bracket end to end.
- Not verified, and the probe says so rather than reporting a number: the scaling of the
  literal-area cleanup could not be isolated cleanly at every holder count. The barrier needed
  to make deferred work observable costs more than the work at low holder counts, so the probe
  prints `swamped` where the difference is inside its own noise. Three earlier versions of that
  section measured the instrument and were discarded.
- 15 unit tests for the ordering rules; 9 integration tests (ordinary Ash write invalidates the
  cache, including atomic update, bulk create, `Ash.count`).
- Commits: `757ec65` (probe), `dd74da3` (cache), `ad3ac3c` (transaction bracket + enum removal).
- Not verified: cache behaviour across multiple nodes reading the same cell (not applicable —
  `:owner`/`:cached` are both owner-local by design).

## Notes

The read number in Option B (0.04 µs) was measured on a *pointer* — four words. Option D's table
shows that is the one shape where ETS is level with `:persistent_term`. The original probe was
not wrong; it asked about the pool and answered that, and the store came along with the answer
untested. Worth remembering as a pattern: a probe settles the question it was built for, and the
choices made alongside it inherit a confidence they have not earned.

If `:replicated` or `:leased` is ever revisited, the per-cell write-cost rule above should be
the first thing checked against the target workload, since it determines whether adding a
lenient resource to a strict cell is safe.
