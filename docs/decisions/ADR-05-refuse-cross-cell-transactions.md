# ADR-05 — Refuse cross-cell transactions rather than build a coordinator

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `ash_cell/lib/ash_cell/manager.ex`

## The decision

Keep the existing guard that raises when a statement for one cell would run inside a transaction
opened for another, and when a transaction is opened for a second tenant inside one already open
for a first. Both nestings are refused, not coordinated. `assert_same_cell!/1` compares cell keys,
not tenants, so two tenants that share one cell (for example, two tenants inside one monthly
window) are correctly treated as one connection and one transaction.

## Context

A user proposal was considered in detail for making a cross-cell transaction work: open one
transaction per cell, track a mapping of transaction id → cell ids, and roll both back on error.

## Options considered

### Option A — per-cell transactions with tracked rollback

Its rollback path is genuinely sound: if either side fails, neither has committed, and both
discard cleanly. Its commit path is not: if cell B's commit fails after cell A has already
committed, there is no undo, and the result is exactly the torn state the coordinator was meant to
prevent. SQLite has no `PREPARE TRANSACTION` equivalent — no durable-but-uncommitted middle state —
so a true atomic commit across two cells is not buildable this way.

### Option B — SQLite's native `ATTACH` plus master-journal internal two-phase commit

Rejected for three reasons, the first fatal. This is reasoned from general SQLite semantics, not
measured — a probe was offered and not run:

- It does not work in WAL mode: each attached database commits atomically on its own, not as a
  set, and cells must stay in WAL mode for replication.
- It requires every cell to be on one connection on one node, which fights per-tenant routing.
- `SQLITE_MAX_ATTACHED` defaults to 10, and every attached cell's SQLCipher key would have to be
  held in that one connection at once.

Even a perfect local atomic commit under this option would not survive recovery: each cell
replicates on its own cadence, so a crash-and-restore can tear a cross-cell transaction apart
regardless of how the commit itself was made atomic.

### Option C — refuse cross-cell transactions outright (chosen)

Cost: no cross-cell atomicity of any kind is available to callers; an application that needs it
must restructure. Benefit: the guarantee offered is exactly what is delivered, with no window of
partial commit.

### Alternatives offered to callers instead of a coordinator

Put both things that must be atomic in one cell — usually a signal the cell boundary is drawn in
the wrong place. Or build an outbox/saga with compensation, and label it plainly as eventual
consistency rather than as a transaction.

## Decision and why

"A coordinator would say 'cross-cell is atomic, except in a window I can detect but not repair' —
which is a weaker guarantee dressed as a stronger one." Refusing is the honest guarantee: nothing
half-commits because nothing spanning two cells is attempted at all. Operational costs were noted
even for the rejected coordinator, reinforcing the decision: `pool_size: 1` means holding a write
transaction open on cell A while coordinating with cell B blocks A's only writer for the whole round
trip, and two concurrent cross-cell transactions taking opposite lock orders would deadlock, making
deterministic lock ordering a hard requirement that was never designed.

## Consequences

- **What it rules out.** Any atomic operation that spans two cells, of any kind — no coordinator,
  no saga with a "transaction" label, no `ATTACH`-based approach.
- **What it makes worse.** Any workload that genuinely needs cross-tenant or cross-window
  atomicity must either be redrawn into one cell (see [ADR-06](ADR-06-own-repo-for-shared-tables.md),
  which applies the same reasoning to shared tables) or accept eventual consistency via an
  explicit outbox/saga.
- **What stays open.** The ATTACH/WAL incompatibility claim is reasoned from general SQLite
  semantics and was not probed against a real database. A probe was offered and not run; this is
  the specific thing to verify before revisiting Option B.
- **What now depends on it.** `assert_same_cell!/1` comparing cell keys rather than tenants — a
  real correctness fix, not a naming change, since two tenants inside one monthly window are one
  connection and refusing that would itself be a bug. [ADR-07](ADR-07-opaque-cell-keys.md)'s cell
  key abstraction depends on this comparison being at the cell-key level.

## Evidence

- `SQLITE_MAX_ATTACHED` default of 10, cited as a hard limit on Option B.
- `pool_size: 1` serialisation, cited as the operational cost that would apply even if a
  coordinator were built.
- Not verified (reasoned, not measured): whether `ATTACH` plus a master-journal actually fails
  under WAL mode as described. No probe was run against real SQLite for this ADR. This must be
  stated as a limit whenever this ADR is cited.

## Notes

This is the ADR to point to whenever a "just coordinate the two cells" proposal comes up again: the
rollback half of that proposal is sound and was never in dispute, only the commit half.
