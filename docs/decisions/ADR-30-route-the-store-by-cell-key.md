# ADR-30 — Choose a cell's object store from its cell key, through `store_for/1`

**Status:** accepted
**Last changed:** 2026-10-21 — `AshCell.Manager.ensure_started/1` resolves the store in the caller. It used to call `store_for/1` inside the manager, so an unknown key crashed the manager instead of raising at the caller's bind.
**Date:** 2026-10-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-07](ADR-07-opaque-cell-keys.md) · [ADR-08](ADR-08-fence-by-shared-txid.md) · [ADR-16](ADR-16-isolation-is-blast-radius.md) · [ADR-18](ADR-18-tenant-in-job-args.md) · [ADR-23](ADR-23-merge-by-fast-forward-or-refuse.md) · [the region demo's design](../../demos/region/docs/design.md) · `lib/ash_cell/object_store/router.ex`

## The decision

A fleet's `store:` option is either one `AshCell.ObjectStore` or a module implementing `AshCell.ObjectStore.Router`. That behaviour has one callback, `store_for/1`, which takes a **cell key** and returns the store holding that cell's snapshots, lease, and generation. It raises for a key it cannot place. Every lookup goes through `AshCell.Manager.store/1`, or through `AshCell.ObjectStore.Router.resolve/2` where a store was passed in. The lookup runs in the calling process, never inside `AshCell.Manager`, so a raise reaches the caller. A branch whose origin and branch keys route to different stores is refused with `{:error, :cross_store_branch}`.

## Context

The region demo keeps each organisation's cell in its own region's bucket. Before this change `AshCell.Manager` held one store for the whole fleet and handed it to every cell. The store functions in `AshCell.Replicator`, `AshCell.Lease`, and `AshCell.Branch` already took the store as an argument, so the decision was only where the per-cell choice is made and what it is given.

## Options considered

### Option A — route by cell key (taken)

`store_for/1` receives the cell key. Every caller that picks a store has one: `AshCell.Manager` starting a cell, `AshCell.Drain.drain_cell/3`, `AshCell.Plug.OwnerRouting` after it resolves the tenant, and `claim/2`, `history/1`, `fork/2`, `merge/1` and `drop_branch/1` in `AshCell`. The region has to be in the key, so changing a cell's region changes its key.

### Option B — route by tenant

`store_for/1` receives Ash's tenant. Below `AshCell.Binder` the library speaks only cell keys ([ADR-07](ADR-07-opaque-cell-keys.md)). A drain walks `AshCell.resident_cells/0`, and a periodic snapshot runs inside the cell process. Neither has a tenant to pass. Supporting this would mean storing the tenant beside every cell.

### Option C — route by Ash scope

A scope struct carrying the region, read by the router. A scope exists only while an Ash action is being called. A drain, a periodic snapshot, and a restore at claim have no scope. A scope also does not survive into an Oban job, which carries the tenant string ([ADR-18](ADR-18-tenant-in-job-args.md)). A scope is still the right place to **build** the key. The region demo's `Region.Scope.get_tenant/1` does that.

### Option D — one bucket with a region prefix

No library change. A bucket has one location, so a prefix proves nothing about where a cell's bytes are stored.

## Decision and why

The store must be chosen wherever a cell's bytes move. Most of those places run with no request and no tenant, only a cell key. Routing by anything else would make the router unavailable on the drain and snapshot paths. Those paths are the ones that write to the bucket.

A router that raises rather than falls back follows from the purpose. A default bucket would turn a misconfigured key into data in the wrong region, with nothing raising.

Branching is refused across stores because `AshCell.Branch.fork/3` copies a snapshot within one store. A cross-store fork would move a cell's data out of the bucket its key names.

## Consequences

- **What it rules out.** Moving a cell to another region without changing its key. Choosing a store from anything a statement or a record carries.
- **What it makes worse.** `AshCell.Manager.store/0` is gone. Callers outside the library that asked the manager for the fleet store now have to name a cell. None of the demos did.
- **What stays open.** A wrong key is a silent misplacement. The router checks that a key names a known region, not that it names the right one for the tenant. Fencing per region is untested beyond the placement test. The txid namespace ([ADR-08](ADR-08-fence-by-shared-txid.md)) lives in the same bucket as the snapshots it fences, so the reasoning carries over. This is argued, not tested.
- **What now depends on it.** The region demo, and every call site listed in option A. `AshCell.Drain` receives the fleet's `store:` option from the supervisor, so it must resolve a router per cell too. A first version did not, and it failed every shutdown drain. `AshCell.Manager.ensure_started/1` resolves the store before calling the manager. A first version resolved it inside the manager's `handle_call/3`, so an unknown key on a statement crashed `AshCell.Manager` and `AshCell.Drain`, and the caller saw an exit.

## Evidence

- `test/store_router_test.exs`, against two MinIO buckets:
  - `each cell's snapshots, lease and generation land only in its own region's bucket`
  - `a cell key the router cannot place fails the claim instead of using a default bucket`
  - `a statement on a cell key the router cannot place raises in the caller and leaves the manager up`
  - `a branch into another region's bucket is refused`
- The full suite passes with `store:` still a single struct: 323 tests, 0 failures, on 2026-10-21.
- `scripts/minio.sh` creates the second bucket, `ashcell-test-eu`.
- Not measured: the cost of `store_for/1` per lookup. The region demo's design names that measurement.

## Notes

`AshCell.Cell.ship_now/1` fails for every cell, with or without a router. It ships from inside the cell's own call, and the snapshot then cannot bind the cell. Nothing calls it, so it is left as found. The placement test ships through `AshCell.Manager.store/1` instead.
