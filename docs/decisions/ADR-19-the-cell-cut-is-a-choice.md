# ADR-19 — Treat the cell cut as a choice, with one cell per tenant as the default

**Status:** accepted
**Last changed:** 2026-08-28 — qualified: the cut is a choice at design time, and changing it later is application work ([ADR-25](ADR-25-no-record-handoff-in-the-library.md))
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-07](ADR-07-opaque-cell-keys.md) · [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md) · [ADR-13](ADR-13-pool-size-one-and-cache.md) · [ADR-25](ADR-25-no-record-handoff-in-the-library.md)

## The decision

Treat what a cell contains as an application-level choice, encoded entirely in the cell key. One
cell per tenant is the default cut, not the only one: because the cell key is opaque
([ADR-07](ADR-07-opaque-cell-keys.md)), per entity, per time window, or per workload all work
without any change to AshCell itself.

## Context

The opaque cell key means storage identity is no longer implicitly "one tenant, one cell." That
raises a real question the library cannot answer on the application's behalf: what should a cell
actually contain. This ADR records the shapes considered and their costs, and names the five demos
as the evidence that the choice is real rather than theoretical.

## Options considered

### Option A — per tenant (default)

Gives transactions and joins across a customer's whole footprint; blast radius is one customer.
Gives up sharding one huge tenant — all its writes serialise on one process.

### Option B — per entity (document, channel, room)

Gives a serializable single writer per entity, ideal for collaborative documents. Gives up
cross-entity queries, and the cell count explodes at roughly 4MB resident each.

### Option C — per tenant per window (e.g. `tenant:2026-08`)

Bounds cell size forever; old windows become cold objects. Gives up cross-window queries without
application-level fan-out and merge.

### Option D — per workload (e.g. `acme:billing`)

Gives independent contention and migration cadence per subsystem. Gives up cross-domain
transactions within a tenant.

### Option E — per user

Gives a real local-first story. Gives up nearly all multi-user features without a global store.

## Decision and why

No single cut dominates; the choice is reasoned rather than measured, and depends on which query
shape and blast radius the application needs. Per tenant is the default because it is the shape
most applications start with and its cost — no sharding within one huge tenant — is the least
common failure mode.

Windowing is singled out as solving the design's weakest point: the `Replicator` moduledoc concedes
that whole-file snapshot cost scales with database size, not change size
([ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md)). Windowing bounds snapshot cost to
O(current window) for the cost of a key-naming convention plus a fan-out read helper — a better
effort-to-benefit ratio than page-level LTX, which would need a NIF. Per-entity cuts make crude
whole-file snapshotting more defensible too: 100KB rather than 2GB.

Costs that scale with cell count — deploy migration and thundering herd on node loss — get worse
under per-entity and are bounded per cell, but not eliminated, under windowing.

Not built: any cross-cell fan-out and merge machinery, which both windowing and per-entity would
need to answer cross-window or cross-entity queries. Placement treats keys independently, so
colocating a tenant's composite-keyed cells on the same node would be new logic, not something the
current design provides.

The five demos are the evidence the cut is a real, application-level choice rather than a
theoretical menu: console cuts per tenant, collab_editor per document, shroud per user, rollout per
release channel, vcs per repository.

Demo-level corollaries worth carrying alongside the cut itself:

- `collab_editor` uses Yjs, so the cell is not what makes its editing correct — a CRDT gives
  convergence, but not a safe place to keep the log. Compaction (merge, snapshot, truncate) is a
  read-modify-write that a CRDT does not make safe, and the cell's single writer does.
- `rollout`'s sharpest claim is that its content-addressed GC is sound because the reference graph
  has exactly one writer.
- `vcs` puts the object move and the ref move in one transaction, so Git's `main.lock` and its
  optimistic retry are not needed.

## Consequences

- **What it rules out.** Nothing at the library level — the cell key stays opaque and the library
  does not assume a cut. It does rule out treating "one cell per tenant" as a hardcoded
  architectural constant anywhere in application code.
- **What it makes worse.** Per-entity and windowed cuts increase cell count, which worsens the
  existing deploy-migration and thundering-herd problems; windowing bounds the effect per cell but
  does not remove it.
- **What stays open.** The cut is a choice made at design time, and **changing it later is not a
  library operation** — moving a record from one cut to another is an application-level migration
  under [ADR-25](ADR-25-no-record-handoff-in-the-library.md)'s ordering, and AshCell does not help
  with it. No cross-cell fan-out and merge machinery exists; any cut needing
  cross-window or cross-entity queries has to build that itself. The cost/benefit analysis above is
  reasoned, not measured.
- **What now depends on it.** All five demos' choice of cut; `AshCell.CellKey.resolve/1`'s contract
  of seeing the tenant value and not the query ([ADR-07](ADR-07-opaque-cell-keys.md)).

## Evidence

- `Replicator` moduledoc: snapshot cost scales with database size, not change size.
- Demo cuts: console per tenant, collab_editor per document, shroud per user, rollout per release
  channel, vcs per repository.
- Per-entity cell size estimate: roughly 4MB resident each (reasoned, not measured).
- Per-entity snapshot size comparison: 100KB versus 2GB (reasoned, not measured).

## Notes

Reasoned, not measured: the cost/benefit specifics for each shape are argued from the design's
known constraints, not from a run against real workloads of each shape.
