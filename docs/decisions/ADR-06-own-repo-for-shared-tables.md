# ADR-06 — Give non-tenanted resources their own repo module

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `ash_cell/test/non_tenanted_test.exs`

## The decision

Give any shared, non-tenanted table its own repo module (the `AshCell.TestGlobalRepo` pattern), and
never reuse the cells' repo module for a resource that is not meant to be tenanted. Plain resources
built this way need nothing AshCell-specific to get transactions — just `write_transactions? true` — since
`AshCell.Resource` itself refuses any strategy other than `strategy :context`.

## Context

Ecto's dynamic binding is keyed by `{repo_module, :dynamic_repo}` in the process dictionary — per
*module*, not per process and not global. That means a bind to one repo module has no effect on any
resource using a different repo module, but it also means a resource sharing the cells' repo module
inherits every bind made to that module, whether or not the resource was meant to be tenanted.

## Options considered

### Option A — share the cells' repo module for shared tables

Tested both ways in `ash_cell/test/non_tenanted_test.exs` (8/8 passing). A non-tenanted resource
sharing the cells' repo module silently inherits bindings: a write issued while bound to "acme"
landed inside acme's cell file, with nothing raising, because the data layer has no way to know a
shared row was meant to be shared. Unbound, it instead fails with "could not lookup Ecto repo ...
not started," since an AshCell application never starts the named repo directly. Both outcomes are
wrong for a table meant to be shared.

### Option B — give non-tenanted resources their own repo module (chosen)

The same test suite proves a resource on its own repo module is immune by construction: a cell
binding touches only the cells' repo module's process-dictionary key, never this one. Cost: an
extra repo module to configure and start per shared table group; a shared-table transaction is now
provably a separate transaction on a separate connection from any cell transaction in the same
logical operation, so rolling back a cell write does not roll back a shared-table write made
alongside it, and vice versa.

## Decision and why

The module-keyed nature of `put_dynamic_repo/1` is the deciding fact, not a preference: it makes
"immune by construction" literally true for Option B and "silently wrong by construction" literally
true for Option A, both demonstrated in the same test file rather than argued separately. The same
reasoning as [ADR-05](ADR-05-refuse-cross-cell-transactions.md) applies to the atomicity gap this
creates: if a cell write and a shared-table write must be atomic together, they belong on one
connection, and that is not what this option offers.

## Consequences

- **What it rules out.** Treating a shared table as if it lived on the same connection as any
  cell. A cell write and a shared-table write in the same logical operation are never atomic
  together under this design.
- **What it makes worse.** Every shared-table group needs its own repo module configured and
  started, rather than reusing infrastructure already in place for cells.
- **What stays open.** Cross-data-layer relationships between a global table (for example,
  Postgres) and a tenant cell support `load` only — no SQL-level filtering, sorting, or aggregating
  across that boundary. The application must denormalise the attributes it filters or sorts by into
  the cell at write time; this is a related but separate constraint, not solved by this ADR.
- **What now depends on it.** Every shared/global resource in the codebase must use a repo module
  distinct from the cells' repo module. `AshCell.Resource`'s restriction to `strategy :context`
  depends on plain resources not needing anything AshCell-specific beyond `write_transactions? true`.

## Evidence

- `ash_cell/test/non_tenanted_test.exs` — 8/8 passing, covering both the shared-module failure mode
  and the own-module immunity.
- Observed failure mode when sharing the repo module: a write bound to "acme" landing inside acme's
  cell file with nothing raising.
- Observed failure mode when unbound and sharing the repo module: "could not lookup Ecto repo ...
  not started."
- Commit: `7609603`.

## Notes

The two failure modes under Option A are worth keeping distinct: one is silently wrong (data lands
in the wrong tenant's file) and one is loudly wrong (a raised error). Only the silent one is
dangerous; it is also the one that motivated this ADR rather than the loud one.
