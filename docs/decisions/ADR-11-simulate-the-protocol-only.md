# ADR-11 — Simulate the coordination protocol only; SQLite and real processes stay out

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/dst.md`](../dst.md) · [ADR-08](ADR-08-fence-by-shared-txid.md) · [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md) · [ADR-20](ADR-20-choose-a-durability-level.md)

## The decision

Build deterministic simulation over pure `step(state, event) -> {state, effects}` cores for
`Manager`, `Drain`, and the lease logic, driven by one simulator process with injectable clock,
randomness, and object store. Keep SQLite and real GenServers out of simulation entirely.

## Context

Repeated bugs found by manual log-reading were all scheduling/interleaving bugs — a cell dies
between lookup and call; a binder arrives between count-zero and close; a node revokes between two
activations. Example-based tests pick one interleaving, and it is almost never the bad one. celld's
DST docs were the reference model.

## Options considered

### Option A — run real GenServers under a simulated clock

Would exercise the actual code paths. Rejected without building: the BEAM scheduler introduces
uncontrolled ordering that breaks seed reproducibility, defeating the point of deterministic
simulation.

### Option B — include SQLite in the simulated boundary

Would catch storage-layer bugs in the same harness. Rejected, following celld's own rule that the
non-deterministic runtime stays out of simulation — V8 for celld, SQLite here — because "it is the
part we are least unsure about, and none of our bugs were in it."

### Option C (chosen) — pure cores plus one simulator process, SQLite and GenServers excluded

Requires a real refactor into decision-free shells around pure cores for `Manager`, `Drain`, and
the lease logic. Cost: every future change to coordination logic must go through the pure-core
shape to stay simulatable, and the simulation's fidelity is bounded by how faithfully the fake
object store models the real one (see the named limit below).

## Decision and why

Stage 0 was built rather than only specified, because its whole purpose was to find out whether the
invariants could be stated precisely at all — and it found 3 real protocol defects, which settled
that the approach was worth the refactor cost.

Per-step checking, not just end-state, is load-bearing: the release-before-snapshot mutant passes
an end-state check because the snapshot has landed by then. The bug is the window, not the final
state — so only a check that runs at every step, not just at completion, catches it.

**Stating "one writer" correctly took three attempts, each correction forced by a surviving
mutant.** "Same generation" was too weak: split-brain holders can sit at different generations and
still both believe they are current. "At most one holder believes it owns the cell" was too
strong: a fenced writer that has not yet noticed its fencing is exactly the safe case fencing
exists for, and forbidding that belief forbids the mechanism itself. The correct form is **"a node
never holds a generation it did not win"** — a node's belief about ownership may be stale, but it
may never be invented.

**Sim-first methodology is itself a corrected decision.** `Protocol.write/5` originally modelled a
durability write on every write, making invariant #2 true by construction rather than by design —
production only acks on local fsync and ships separately, so the simulation did not match
production's actual acknowledgement point. Rather than porting the fix straight into real code, the
simulation was changed first to model production faithfully, and the invariant was watched to fail
— "an invariant suite that has never caught a mutant is indistinguishable from one that cannot."
That split invariant #2 into three: `no_shipped_write_lost`, `drain_loses_nothing`,
`fenced_node_stops_acknowledging` (implemented by [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md)).
`drain_loses_nothing` was itself wrong as first stated, scoped "over every acknowledgement for a
cell" — under that scope, a successor's ordinary unshipped write looked like the predecessor's
drain losing data. It had to be rescoped to only what the draining node itself accepted.

The stale-successor mutant could not be constructed under local-counter fencing (the mechanism from
[ADR-08](ADR-08-fence-by-shared-txid.md)), proving backwards shipping is structurally unreachable
rather than merely unlikely. It became a positive test, replaced by the `:reread_high_water`
mutant.

**Named limit, from the spec's own §9:** the fake object-store model encodes *believed*
conditional-write semantics. If that belief is wrong, the simulator will agree with itself
confidently at scale — a simulation cannot discover that its own model of the dependency is wrong.
A separate conformance run against real MinIO, R2 and Tigris is required, because "S3-compatible"
is doing a lot of work in the correctness story.

## Consequences

- **What it rules out.** Testing coordination logic by running real GenServers under a fault
  injector, or by including SQLite's own behaviour inside the simulated boundary.
- **What it makes worse.** Every coordination-logic change now requires the pure-core/shell split;
  a change that cannot be expressed as `step(state, event) -> {state, effects}` cannot be
  simulated without further refactoring.
- **What stays open.** The fake object store's fidelity to real S3-compatible stores is asserted,
  not verified within this suite — the §9 limit is named but not closed by anything in this ADR.
- **What now depends on it.** [ADR-08](ADR-08-fence-by-shared-txid.md)'s fencing correction was
  found by this harness, not by manual review. [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md)'s
  behaviour is validated against `fenced_node_stops_acknowledging`. [ADR-20](ADR-20-choose-a-durability-level.md)
  is explicitly out of reach of this simulation, since the simulator models the object store, not
  fsync behaviour.

## Evidence

- `docs/dst.md`; `test/dst_stage0_test.exs`.
- 13 Stage 0 tests green, later 17 after the invariant #2 split; 117 tests stable across three
  runs.
- Commits: `2b9dba4`, corrected by `c504c91`.

## Notes

A separate conformance run against real MinIO, R2 and Tigris is required and is not yet built —
carried here as the named limit from the spec's §9, not as a resolved item.
