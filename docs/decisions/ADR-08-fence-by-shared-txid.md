# ADR-08 — Fence durability by a shared txid namespace, not by lease generation

**Status:** corrects an earlier belief
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/dst.md`](../dst.md) · [ADR-09](ADR-09-snapshot-before-releasing-the-lease.md) · [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md) · [ADR-11](ADR-11-simulate-the-protocol-only.md) · [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md)

## The decision

Key every durability write by txid, from one namespace per cell shared by every owner past and
present (`AshCell.Replicator.snapshot_key/2`), and give the generation counter its own object
independent of the lease body. Read the high-water mark once, at adoption
(`AshCell.Lease.claim/4`), and advance it only locally, via `AshCell.Manager.commit_txid/2`.

## Context

`AshCell.Lease`'s own moduledoc claimed that conditional writes provide correctness "so being
wrong about a lease does not cost data." That claim was false as written, and it was found false
by DST Stage 0 mutation testing, which revealed the simulation and the shipped code implemented
*different* protocols. The shipped `Replicator.snapshot/3` keyed durability writes by lease
generation: `cells/#{tenant}/snapshots/#{pad(generation)}.db`.

That does not fence, because successive owners never share a generation. A displaced writer at
generation 1 addresses a key its successor at generation 2 never touches. The conditional PUT
returns `{:ok, etag}`, the caller is acknowledged, and the write is silently superseded the moment
the successor snapshots — nothing is refused anywhere. This was measured, not reasoned: the
fenced write's PUT returned `{:ok, etag}`.

A second bug compounded the first: the generation counter was derived from the lease body, and
`Lease.release/2` deletes the lease, so a clean handoff restarted the generation at 1, handing two
successive owners the same number. Measured: **1 → 1** across a clean handoff, before the fix.
After giving the generation counter its own object: **1 → 2**.

## Options considered

### Option A — key durability writes by lease generation (the shipped, wrong protocol)

Simple: the generation is already computed at claim time. Cost: does not fence at all, as
measured above — a displaced writer's PUT lands at a key the successor never reuses, so the
conditional write can never collide and refuse it.

### Option B (chosen) — key durability writes by txid, shared namespace per cell

One txid namespace per cell, shared by every owner past and present. Both a displaced writer and
its successor compute the same next number, so the loser's conditional PUT collides and returns
`{:error, :precondition_failed}` before the caller is acknowledged. Cost: re-keying is a breaking
change to object layout in the bucket — accepted because nothing was in production. This is why
celld keys LTX segments by TXID rather than by epoch.

## Decision and why

The fix is decided by the measurement, not by argument: `{:ok, etag}` for a fenced write under
generation-keying, `{:error, :precondition_failed}` for the same scenario under txid-keying. A
DST mutant `:reread_high_water` violates the invariant immediately if the high-water mark is
re-read before a write, which is why the mark is read once, at adoption, and advanced only
locally.

**The locality is the mechanism, not an optimisation.** Re-reading the high-water mark before a
write would let a fenced writer read its successor's mark and write safely past it — the very
collision that makes fencing work would be erased by the re-read. Advancing it only from local
state means a fenced writer's local counter is frozen at the moment it was displaced; it can never
learn what its successor has already claimed, so it can never target a free slot.

**A store that cannot be read fails the claim.** `latest_txid/2` returns `{:ok, 0}` only for a
cell that has genuinely never shipped; a listing error propagates rather than being read as "start
again at 1". Collapsing the two would let a cell with fifty snapshots adopt a mark of 0 and start
reclaiming txids already in use. The same shape of bug was found and fixed in `next_generation/2`,
which had read a store error as "start again at 1" — handing out a duplicate generation and
unfencing a current holder.

## Consequences

- **What it rules out.** Any scheme that derives fencing identity from the lease body or from a
  per-owner counter that resets on handoff.
- **What it makes worse.** The object layout changed (breaking, though harmless pre-production);
  a store-read failure now fails the claim outright rather than degrading gracefully, which is
  intentional but means a flaky store blocks adoption rather than allowing it.
- **What stays open.** [ADR-20](ADR-20-choose-a-durability-level.md) — this ADR fences the write
  *once it reaches the object store*; it says nothing about whether the local commit that precedes
  it was itself durable.
- **What now depends on it.** [ADR-09](ADR-09-snapshot-before-releasing-the-lease.md)'s ordering,
  [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md)'s fail-closed behaviour on a refused
  shipment, [ADR-11](ADR-11-simulate-the-protocol-only.md)'s `fenced_node_stops_acknowledging`
  invariant, and [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md)'s periodic snapshot, which
  notes that because snapshots are whole files, re-reading the high-water mark mid-write would be
  catastrophic rather than merely wrong.

## Evidence

- `test/fencing_test.exs` holds both halves — that the txid scheme collides, and that the
  generation scheme would not.
- `test/dst_stage0_test.exs:87` predicted the defect.
- Measured: fenced write under generation-keying → `{:ok, etag}`. Generation across a clean
  handoff before the fix → 1 → 1; after → 1 → 2.
- Test speed note: the unreachable-endpoint version of the store-failure test took 13.1s (Req's
  retry defaults); a revoked/deleted-bucket scenario exercises the same code path in 0.1s.
- Test-isolation constraint found alongside: cell names in the suite must carry wall-clock time,
  since `System.unique_integer/1` restarts from small numbers each VM run while the bucket
  outlives every run — a name built from it alone inherits a previous run's lease and snapshots.
  Fix promoted to `AshCell.ObjectStoreCase.unique_cell/1`, invalidating an earlier "155 tests, 0
  failures" claim. Verified stable across 5 runs after.
- Commits: `a39d855`, hardened by `e0b22af`. Corrects `9294ebf`.

## Notes

The corrected claim belongs in `AshCell.Lease`'s moduledoc itself, not only here — the false
statement was load-bearing documentation, not a comment.
