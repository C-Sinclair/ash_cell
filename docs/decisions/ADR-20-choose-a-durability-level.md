# ADR-20 — Choose SQLite's durability level (`synchronous`)

**Status:** proposed
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-11](ADR-11-simulate-the-protocol-only.md) · [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md)

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

### Option B — `synchronous: :full`

What it buys: a returned `COMMIT` is fsynced, closing the gap with `no_acknowledged_write_lost`.
What it costs: unknown. No throughput measurement has been taken comparing it against `:normal`.

## Decision and why

No decision has been made. This is stated plainly and deliberately: the choice between `:normal`
and `:full` needs a measured throughput comparison, not an assumption in either direction. Nothing
in the evidence establishes what that comparison would show. Until that measurement exists, this
ADR records the risk and the question, not an answer.

What it would take to make a decision: a throughput comparison of `:normal` versus `:full` under a
realistic write load, measured the way [ADR-13](ADR-13-pool-size-one-and-cache.md)'s pool-size
question was measured — with a probe script, not an estimate — followed by a decision about
whether the throughput cost of `:full` is acceptable against the correctness gap it closes.

## Consequences

- **What it rules out.** Nothing yet. No choice has been foreclosed.
- **What it makes worse.** Nothing yet, because nothing has changed.
- **What stays open.** Everything: whether `:normal` or `:full` is used, and by extension whether
  `no_acknowledged_write_lost` holds in production. This risk is live right now, not merely
  theoretical — the current default is `:normal`, unexamined, in a system whose DST suite cannot
  detect the gap because the simulator does not model fsync behaviour at all.
- **What now depends on it.** Nothing should depend on either answer yet; this ADR exists so that
  nobody mistakes the current default for a considered choice.

## Evidence

- exqlite's default is `synchronous: :normal`; `cell.ex` does not override it.
- DST invariant `no_acknowledged_write_lost` and the simulator's model of the object store, not
  fsync behaviour, from [ADR-11](ADR-11-simulate-the-protocol-only.md).
- No measurement of `:normal` versus `:full` throughput has been taken.

## Notes

Named as the top open risk on the project: "could lose data without anyone noticing." A future
revisit needs the throughput probe described above before this ADR can move to `accepted`.
