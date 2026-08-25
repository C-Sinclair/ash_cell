# ADR-20 — Choose SQLite's durability level (`synchronous`)

**Status:** proposed — still open, but with a plan that can close it
**Last changed:** 2026-08-25 — added Option C (per-cell policy), and the argument that a throughput
measurement is necessary but *not sufficient* to close this: it needs a test that can fail.
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-11](ADR-11-simulate-the-protocol-only.md) · [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md) · [ADR-13](ADR-13-pool-size-one-and-cache.md) · [ADR-19](ADR-19-the-cell-cut-is-a-choice.md) · `demos/ledger/docs/design.md`

## The decision

No decision has been made. This ADR records the open question, not a choice: exqlite defaults to
`synchronous: :normal`, and `cell.ex` does not override it. Whether to keep `:normal` or move to
`:full` is undecided.

## Context

In WAL mode, `synchronous: :normal` means a returned `COMMIT` is not necessarily fsynced, so recent
commits can vanish on power loss or a kernel panic. This directly undermines the DST invariant
`no_acknowledged_write_lost`: the simulator in [ADR-11](ADR-11-simulate-the-protocol-only.md) models
the object store, not fsync behaviour, so it will keep agreeing with itself regardless of which
`synchronous` level is set. This has been named the top open risk on the project — data could be
lost without anyone noticing.

## Options considered

### Option A — `synchronous: :normal` (current default, unexamined)

What it buys: whatever exqlite's default throughput is; nothing has been changed to get it. What it
costs: a returned `COMMIT` is not durable against power loss or a kernel panic in WAL mode. This is
the status quo, not a decision to keep it.

### Option B — `synchronous: :full` everywhere

What it buys: a returned `COMMIT` is fsynced, closing the gap with `no_acknowledged_write_lost`.
What it costs: unknown. No throughput measurement has been taken comparing it against `:normal`.
The cost is paid by every cell, including ones whose contents are a cache and whose loss window
nobody would care about.

### Option C — durability as a per-cell policy

`synchronous` is a first-class connection option — `:extra | :full | :normal | :off`,
defaulting to `:normal` (`deps/exqlite/lib/exqlite/connection.ex:115`) — and it is set per
connection, so per cell. AshCell never sets it today.

What it buys: a ledger cell takes `:full` and pays the fsync; a cache-shaped or
projection-rebuild cell stays `:normal`. The tradeoff becomes explicit at the declaration site
rather than global and invisible, which is the same argument
[ADR-19](ADR-19-the-cell-cut-is-a-choice.md) makes about the cut itself.

What it costs: two durability levels in one fleet means the answer to "is an acknowledged write
durable here?" is "it depends on the cell", and every claim in the docs has to be qualified by
which policy the cell runs under. It also makes the DST invariant `no_acknowledged_write_lost`
conditional, which is worse than either uniform answer.

## Decision and why

No decision has been made. This is stated plainly and deliberately: the choice between `:normal`
and `:full` needs a measured throughput comparison, not an assumption in either direction. Nothing
in the evidence establishes what that comparison would show. Until that measurement exists, this
ADR records the risk and the question, not an answer.

What it would take to make a decision — and the second half of this is new, because the first half
alone cannot close it:

**1. Measure the cost.** A throughput and latency comparison of `:normal` versus `:full` (and
`:extra`) under a realistic write load, measured the way
[ADR-13](ADR-13-pool-size-one-and-cache.md)'s pool-size question was measured — a probe script,
median of 5, not an estimate. Include a group-commit variant: batching amortises the fsync, and
if it makes `:full` affordable then the whole tradeoff changes shape.

**2. Build a test that can fail.** This is what has been missing, and it is why the risk has
stayed live. **Killing the process proves nothing about fsync** — the page cache survives process
death, so every existing test passes under `:normal` and would keep passing under it no matter how
wrong `:normal` is. The gap is only observable across a *machine* boundary:

- A VM whose power is cut: run a cell inside QEMU, `kill -9` the VM mid-commit, boot it, and
  assert the last acknowledged commit is present. Crude, real, and runnable.
- Better, on Linux CI: `dm-log-writes` or `dm-flakey` to capture the block stream and replay it to
  an arbitrary prefix, asserting every prefix leaves a valid database and no acknowledged write is
  missing.

[ADR-11](ADR-11-simulate-the-protocol-only.md) is explicit that the simulator models the object
store and not fsync, so it will keep agreeing with itself regardless. Whatever closes this ADR has
to touch real I/O.

**3. Decide the shape**, between B and C, with the measurement in hand — and record which claims in
the docs and demo READMEs become conditional if C wins.

## Consequences

- **What it rules out.** Nothing yet. No choice has been foreclosed.
- **What it makes worse.** Nothing yet, because nothing has changed.
- **What stays open.** Everything: whether `:normal` or `:full` is used, and by extension whether
  `no_acknowledged_write_lost` holds in production. This risk is live right now, not merely
  theoretical — the current default is `:normal`, unexamined, in a system whose DST suite cannot
  detect the gap because the simulator does not model fsync behaviour at all.
- **What now depends on it.** The `ledger` demo (`demos/ledger/docs/design.md`) depends on it
  directly and should not claim durability until this closes: an event store's entire contract is
  that the log is the truth, so a lost event there is not stale data but state that never happened,
  with balances already derived from it. More generally, every structure drafted in
  `docs/design/DD-05` through `DD-12` inherits whatever is decided here, and
  [DD-08](../design/DD-08-durable-execution.md) names this ADR as a hard gate on its own work.

## Evidence

- exqlite's default is `synchronous: :normal`; `cell.ex` does not override it.
- DST invariant `no_acknowledged_write_lost` and the simulator's model of the object store, not
  fsync behaviour, from [ADR-11](ADR-11-simulate-the-protocol-only.md).
- No measurement of `:normal` versus `:full` throughput has been taken.
- `synchronous` is settable per connection: `deps/exqlite/lib/exqlite/connection.ex:115`
  (`:extra | :full | :normal | :off`, default `:normal`) and
  `deps/ecto_sqlite3/lib/ecto/adapters/sqlite3.ex:24`. `lib/ash_cell/cell.ex` passes neither, so
  every cell in the fleet currently runs `:normal` by omission rather than by choice. Read at
  exqlite 0.33 / ecto_sqlite3 0.21, 2026-08-25.
- **Not verified, and it is the point of the plan above:** that `:full` actually survives a
  power-loss event on the target filesystem. macOS in particular has a history of `fsync` not
  reaching stable storage without `F_FULLFSYNC`, so "we set the pragma" is not evidence that the
  guarantee holds — only a fault-injection test is.

## Notes

Named as the top open risk on the project: "could lose data without anyone noticing." A future
revisit needs the throughput probe described above before this ADR can move to `accepted`.
