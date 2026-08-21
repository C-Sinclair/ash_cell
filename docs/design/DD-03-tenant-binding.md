# DD-03 — Tenant binding

**Status:** built
**Date:** 2026-08-21
**Decisions:** [ADR-01](../decisions/ADR-01-bind-tenants-per-process.md), [ADR-02](../decisions/ADR-02-bind-in-the-data-layer.md), [ADR-03](../decisions/ADR-03-fork-ash-sqlite-narrowly.md), [ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md), [ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md), [ADR-06](../decisions/ADR-06-own-repo-for-shared-tables.md), [ADR-07](../decisions/ADR-07-opaque-cell-keys.md), [ADR-18](../decisions/ADR-18-tenant-in-job-args.md)
**Lands in:** `lib/ash_cell/binder.ex`, `lib/ash_cell/cell_key.ex`, `lib/ash_cell/resource.ex`, `lib/ash_cell/resource/`, `lib/ash_cell/job.ex`, `lib/ash_cell/live_view.ex`, `ash_sqlite/lib/tenant_binder.ex` (fork)

## What this is

How an ordinary `Ash.read!(Patient, tenant: "acme")` ends up running against `acme`'s own
SQLite file rather than whichever file the calling process happens to have bound: a fork seam
(`tenant_binder`) that lets the data layer ask, once per statement, which connection to use.

## What this proves

- `AshCell.Resource` resources need no caller ceremony at all — no `with_tenant/2` at call
  sites — across reads, aggregates, atomic updates, atomic destroys, and bulk writes.
- Multi-step actions on a cell are transactional (`transactions? true`), and a transaction
  cannot silently span two cells.
- A non-tenanted resource sharing the cells' repo module silently inherits whatever tenant
  happens to be bound; giving it its own repo module makes it immune by construction.
- A background job carries its tenant explicitly and fails closed, rather than than inheriting
  a binding that does not survive process boundaries.

## Why it needs a cell

This is the seam that makes "database per tenant" invisible to application code. Without it,
every entry point — controller, `Task`, `Ash.load` fan-out, LiveView callback, Oban job — would
need to know it must bind, including the ones where binding is not obviously possible
(`Ash.count/2` never enters `Ash.Actions.Read`; an atomic update never materialises a
changeset to hook).

## Non-goals

- Not a general multi-tenancy story for AshPostgres-style row tenancy — SQLite has no schemas,
  so `set_tenant/3` is a documented no-op; isolation comes entirely from which file the
  connection points at.
- Not cross-cell transactions. A statement for another tenant inside an open transaction
  raises, rather than committing independently.
- Not automatic job placement — a job binds a cell on whichever node it runs on; routing that
  job to the node that owns the cell is left undone (ADR-18).

## Data model

Three vocabularies, deliberately kept distinct rather than collapsed into one
([ADR-07](../decisions/ADR-07-opaque-cell-keys.md)):

1. Ash's **tenant** — unchanged at every Ash-facing edge: `tenant_binder`, `CarryTenant`,
   `Binder`, `Resource`, `LiveView`, `Job`.
2. AshCell's **cell key** — the registry key, file path, and object-store prefix.
   `AshCell.CellKey.resolve/1` maps tenant → cell key once, at `AshCell.bind/1`; everything
   below the binder speaks only cell keys.
3. The **encoding** of a cell key into a path-safe string. `AshCell.CellKey.encode/1` is
   injective; a prior sanitising scheme that replaced awkward bytes with `_` was not, and
   mapped `"a:b"` and `"a_b"` onto the same file — two cells sharing a database with nothing
   raising. Two real path-traversal-shaped bugs were fixed alongside this: `Manager`
   interpolating a raw key into `Path.join/2` (a `"../../etc/x"` key wrote outside the cell
   directory), and lease/snapshot object keys interpolating a key containing `/` to forge
   object-store prefixes.

A non-tenanted resource lives on its own repo module, never the cells' repo module — the only
way to be immune to a cell binding, since Ecto keys the dynamic binding as
`{repo_module, :dynamic_repo}`, per module rather than per process
([ADR-06](../decisions/ADR-06-own-repo-for-shared-tables.md)).

## Trade-offs

- **Per-process `put_dynamic_repo/1`, not a query-context pid**
  ([ADR-01](../decisions/ADR-01-bind-tenants-per-process.md)). The query-context override is
  real and consulted first, but both the read and write paths invoke the result as a *module*;
  a pid raises `ArgumentError`. The override therefore selects a repo module (primary vs
  replica); binding an instance is Ecto's job, and Ecto binds per process. Consequence: the
  binding does not survive `Task.async`, `Ash.load` fan-out, or an Oban job.
- **Bind in the data layer via `tenant_binder`, not action hooks or call sites**
  ([ADR-02](../decisions/ADR-02-bind-in-the-data-layer.md)). Two earlier approaches were built
  and deleted: caller-side `with_tenant/2` everywhere (unergonomic, misses entry points with
  "no obvious entry point"); global preparation/change hooks (`Ash.Query.for_read/4` consumes a
  query's `around_transaction` hooks before an unvalidated query's preparations run, so the
  hook silently never fires; `Ash.count/2` skips `Ash.Actions.Read` entirely; a hook-carrying
  changeset forces `require_atomic? false`). The chosen seam asks the binder once per
  statement, from the process about to issue it, and fails closed when no tenant is bound.
- **Fork `ash_sqlite` narrowly rather than vendor it**
  ([ADR-03](../decisions/ADR-03-fork-ash-sqlite-narrowly.md)). The fork diff is 534 insertions,
  12 deletions across 5 commits, touching only `lib/data_layer.ex`, `lib/data_layer/info.ex`,
  a new `lib/tenant_binder.ex`, and tests — 12 lines of existing upstream code modified.
  Vendoring would mean adopting roughly 8,486 lines of lib and 4,206 of tests to own 534 (a 16:1
  ratio) and would not buy independence, since `ash_sqlite` itself rides `ash_sql`. A test
  rebase onto current upstream, including an upstream commit touching the forked area,
  succeeded 5/5 commits with zero conflicts.
- **Transactions behind an opt-in `transactions?` flag**
  ([ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md)), default off so
  upstream behaviour is unchanged. Globally re-enabling transactions broke 9 pre-existing
  tests, because `Ash.DataLayer.transaction/5` fires above the data layer with no tenant in
  scope. `AshCell.Resource.Changes.CarryTenant` carries the tenant through
  `changeset.context[:data_layer]`; `reason_tenant/1` handles the three shapes (single-record,
  bulk, read). Writes use `BEGIN IMMEDIATE`: a deferred read-then-write transaction fails an
  upgrade immediately regardless of `busy_timeout` (measured: two deferred transactions racing
  → one `Exqlite.Error`; the same pair immediate → both commit).
- **Refuse cross-cell transactions rather than build a coordinator**
  ([ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md)). A per-cell-transaction
  coordinator's rollback path is sound but its commit path is not — SQLite has no durable
  uncommitted middle state, so a partial commit cannot be undone. `ATTACH` plus a master-journal
  2PC does not work in WAL mode, which cells must be in for replication. `assert_same_cell!/1`
  compares cell keys, not tenants, so two tenants inside one composite window correctly share
  one transaction.
- **Tenant carried in job args, fail closed on absence**
  ([ADR-18](../decisions/ADR-18-tenant-in-job-args.md)). A job with no tenant id is cancelled,
  not retried, since retrying cannot fix a structural absence. Routing a job to the owning node
  is explicitly left undone.
- **Bind per LiveView callback, never at mount** — covered in DD-01 (`AshCell.Holders`); the
  binding half of the mechanism is this doc's concern, the quiescence-tracking half is DD-01's.

## Measurements this must produce

- `test/probe_test.exs` (6 tests): Ash routes queries to a per-tenant database, isolation
  verified by reading files directly, bypassing Ash.
- `test/binder_test.exs` (11 tests): binder correctness across usages; suite at 128/0 at that
  point.
- `test/non_tenanted_test.exs` (8/8): own-repo-module immunity proven both ways — an isolated
  write stays isolated; a shared-repo write lands inside the wrong tenant's cell file with
  nothing raising.
- Transaction feature branch: `ash_cell` 147/0, `ash_sqlite` 160/0 (154 existing + 6 new,
  upstream path unaffected).

## Staging

1. `AshCell.with_tenant/2` at call sites — the first working version, later superseded.
2. Global preparation/change hooks — built, then deleted once each of the three failure modes
   was confirmed against source.
3. `tenant_binder` fork seam plus `AshCell.Binder` — the shipped mechanism. `AshCell.Resource`
   collapses to setting `tenant_binder AshCell.Binder`; the preparation, change, and
   transformer from step 2 are deleted.
4. `:usage` (`:read | :write | :transaction`) added to the seam, because only the data layer
   knows which kind of statement is about to run — this is what later made the read cache in
   DD-04 possible.
5. Transactions enabled behind `transactions?`, `CarryTenant` added to route the tenant into
   `transaction/4`.
6. Cross-cell transaction refusal (`assert_same_cell!/1`) hardened to compare cell keys rather
   than tenants.
7. Cell keys separated from tenants (`AshCell.CellKey`), with the two path-traversal bugs fixed
   as part of the same change.

## Where it stops

- `assert_bound!/0` only checks that *some* tenant is bound, never that it is *this* tenant — a
  process bound to clinic-7 running a query context-tagged `tenant: "clinic-9"` silently
  returns clinic-7's rows. A floated fix (an `ash_sql` patch branching on `is_pid`) was judged
  a bigger upstream ask and never filed.
- Job placement is not solved — a job binds wherever it runs, correct only once ownership
  routing exists elsewhere.
- `bind_held/1`'s binding half is redundant now that `AshCell.Resource` binds itself; it
  remains only for holder registration.

## Open risks

- The tenant-mismatch gap in `assert_bound!/0` above is unresolved and silent by construction.
- Background jobs have no request boundary to route at; this doc's job-args fix carries the
  tenant but does not place the job on the right node.
- The nested-savepoint caveat in exqlite (single fixed savepoint name) is untested at
  transaction depth ≥ 2, relevant to any resource nesting `AshCell.transaction/2` calls.
