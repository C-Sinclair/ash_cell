# DD-09 — Counters, quotas, and rate limits

**Status:** draft
**Date:** 2026-08-24
**Decisions:** [ADR-08](../decisions/ADR-08-fence-by-shared-txid.md), [ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md), [ADR-20](../decisions/ADR-20-choose-a-durability-level.md), [ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md)
**Lands in:** `lib/ash_cell/counter.ex` (new)

## What this is

Exact per-tenant counters with a two-tier store: the hot value in the cell's process state, the
durable value in a SQLite row, flushed on a threshold, a tick, or a read that demands durability.
On top of that primitive: quotas (a counter with a ceiling and an atomic check-and-increment),
rate limits (a counter over a window), and usage meters for billing.

It is the smallest feature in this set and makes the sharpest point: exclusive ownership turns a
distributed-systems problem into a variable.

## What this proves

- The count is **exact**, not approximate, under concurrency: N concurrent increments in one cell
  produce exactly N, because there is one writer and no CRDT, no read-modify-write race, and no
  redis-style "close enough".
- A quota ceiling is never exceeded: check-and-increment is one operation in one process, so
  "allow if under limit" cannot admit two callers at the boundary.
- Increments cost roughly a message send when the flush threshold is not hit, and the durable
  value never leads the in-memory one.
- The unflushed window is **bounded and stated**: a crash loses at most the configured flush
  interval or threshold, whichever is tighter, and the API makes the caller choose.
- A quota that must never be exceeded even across a crash can be had, by flushing before
  admitting — with the measured latency cost of that mode shown next to the cheap one.

## Why it needs a cell

Take the standard alternatives. A shared Postgres row: correct, and a fleet-wide hot row with
lock contention proportional to tenant traffic. Redis `INCR`: fast, approximate under failover,
and a second stateful system. A CRDT counter: converges, cannot enforce a ceiling — the exact
thing a quota needs. Each of these is buying *mutual exclusion over one integer* from a
distributed system.

A cell already has it. The counter is not clever; the ownership is, and it was already paid for.
This is the feature to point at when explaining why the primitive is worth having.

The cut matters ([ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md)): a per-tenant counter
is one cell, but "requests per minute per API key" wants a per-key or per-window cut, and
`"acme:2026-08"` as a monthly billing cell is the natural shape for a meter.

## Non-goals

- **Not a global counter.** A fleet-wide total requires reading every cell, or a rollup pipeline
  that is the application's. Nothing here aggregates across cells.
- **Not a distributed rate limiter.** A limit spanning tenants (a shared upstream API budget) is
  not this, and pretending otherwise is exactly the kind of overclaim this repo is careful about.
- **Not a time-series store.** A meter records a running total and optionally per-window rows; it
  is not a metrics backend and will not answer "graph the last 90 days at minute resolution".
- **Not lossless without asking.** The default trades a bounded loss window for speed. Losslessness
  is a mode, priced.
- **Not a leaky-bucket library.** One window algorithm (fixed window), plus enough primitive to
  build others outside.
- **Not exempt from [ADR-20](../decisions/ADR-20-choose-a-durability-level.md).** Even a flushed
  counter is only as durable as a committed SQLite write currently is, and the two loss windows
  compound.

## Data model

One table per cell, `ash_cell_counters`: `name` (primary key), `value` (integer), `window_start`
(nullable utc datetime), `limit` (nullable integer), `updated_at`. A windowed counter resets by
comparing `window_start` at read time rather than by a scheduled job, so a cold cell needs no
timer — though a [DD-07](DD-07-durable-timers.md) timer is the right tool if a window boundary
must produce an *effect*.

Cell process state holds `%{name => {durable_value, delta, last_flush}}`. Two invariants:

- `durable_value + delta` is the current value, and reads answer from that.
- `durable_value` never exceeds the true value, so a crash undercounts rather than over — which is
  the safe direction for a meter and the *unsafe* direction for a quota, hence the flush-before-admit
  mode.

For a quota, `limit` lives in the row rather than in config, because a per-tenant limit is data.

## Trade-offs

- **Flush on threshold vs on interval vs both.** Threshold bounds loss by count, interval by time;
  a counter incremented once an hour flushes never under threshold alone. Chosen: both, whichever
  fires first, defaults stated in config and the loss window derived from them in the docs.
- **`persistent_term` vs process state for the hot value.** The read cache measurement
  ([ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md)) makes `persistent_term` writes the
  expensive direction, and a counter is write-heavy. Chosen: process state, read via the cell —
  which costs a message send per read and is measured below.
- **Read via the cell vs read from the durable row.** Reading the row is cheap and can be stale by
  the flush window; reading the cell is exact and serialises on the cell's mailbox. Chosen: both,
  as `value/2` and `durable_value/2`, named so the difference cannot be missed.
- **Enforce the ceiling in the cell vs in the SQL statement.** In SQL (`UPDATE … WHERE value < limit`)
  is durable and costs a write per check. In the cell is a comparison. Chosen: in the cell by
  default, in SQL under the lossless mode.

## Measurements this must produce

Warm cell, median of 5:

- **Increments/sec** through the cell, and the same for the flush-before-admit mode. The ratio
  between them *is* the price of losslessness and is the number this feature owes.
- **Read latency** for `value/2` (via the cell mailbox) vs `durable_value/2` (via the binder), and
  both against the DD-04 baseline of a pointer read (17.0 µs) so the cost is comparable to
  something known.
- **Mailbox contention**: increments/sec at 1 / 8 / 64 concurrent callers against one cell, to find
  where the single mailbox becomes the bottleneck. A **cliff**: state the concurrency at which p99
  increment latency crosses 1 ms.
- **Loss window, measured not asserted**: kill the cell mid-run and report the actual delta lost at
  each flush setting, rather than trusting the configured bound.
- **Comparison, one number each**: the same 64-concurrent-caller increment throughput against a
  shared Postgres row and against Redis `INCR`, with the correctness difference stated beside it.
  Slower-but-exact is a fine result; unmeasured is not.

## Staging

1. **Plain durable counter**, no in-memory tier: `increment/3`, `value/2`, one row per name.
   Checkable: N concurrent increments equal N.
2. **In-memory tier with flush** on threshold and interval. Checkable: the two invariants above
   under a property test; a killed cell undercounts by no more than the configured bound.
3. **Quota**: `check_and_increment/3` returning `{:ok, new}` or `{:error, :limit}`. Checkable: a
   ceiling is never exceeded under 64 concurrent callers; the lossless mode holds across a kill.
4. **Windowed counter** and reset-at-read. Checkable: window rollover with no timer; a cold cell's
   first read after a window boundary reports zero, not the old window's value.
5. **Measurements**, including the comparison numbers.
6. **A demo use**: `console` seat counts or `shroud` per-user request limits.

## Where it stops

- One cell. No fleet-wide totals, no cross-tenant limits, no rollup.
- The default mode loses up to the flush window on a crash. For a billing meter that is a revenue
  question the operator must answer, not a detail.
- Reads through the cell serialise on its mailbox, so a read-heavy counter is a bottleneck the
  cheap tier does not remove.
- Only fixed windows. Sliding windows and token buckets are buildable on the primitive and not
  shipped.
- A counter in a *forked* cell ([DD-05](DD-05-time-travel-and-forks.md)) double-counts against the
  origin's quota if both are live, and nothing prevents that.
- Durability is [ADR-20](../decisions/ADR-20-choose-a-durability-level.md)'s open question, and for
  the lossless mode that is the entire claim.

## Open risks

- **"Exact" is doing a lot of work and must be scoped precisely in the docs.** It means exact given
  the cell's durability; with [ADR-20](../decisions/ADR-20-choose-a-durability-level.md) open, a
  flushed increment can still be lost. The word should not appear unqualified in a README.
- Whether the in-memory tier earns its complexity at all — if the plain durable counter from stage 1
  is fast enough at realistic rates, stage 2 should be dropped rather than shipped. The stage-1
  measurement decides, and this doc should be edited to say so once it exists.
- The comparison against Redis invites a benchmark argument. Better to publish one honest number
  with the exactness difference beside it than a suite.
