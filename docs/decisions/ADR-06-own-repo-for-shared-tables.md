# ADR-06 — Give non-tenanted resources their own repo module

**Status:** accepted
**Last changed:** 2026-10-17 — sharing the cells' repo module is no longer a silent inheritance. Upstream `ash_sqlite` makes a repo that implements `tenant_repo/2` serve `strategy :context` resources only: a resource without it on such a repo is reported by a compile-time verifier and raises on its first statement. Transactions for a shared table come from its repo's `write_transactions?/0`.
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `ash_cell/test/non_tenanted_test.exs`

## The decision

Give any shared, non-tenanted table its own repo module (the `AshCell.TestGlobalRepo` pattern), and
never put a resource that is not meant to be tenanted on the cells' repo module. AshSqlite now
refuses that, so this is enforced rather than advised. A shared table needs nothing AshCell-specific
to get transactions: its repo returns `true` from `write_transactions?/0`.

## Context

Ecto's dynamic binding is keyed by `{repo_module, :dynamic_repo}` in the process dictionary — per
*module*, not per process and not global. That means a bind to one repo module has no effect on any
resource using a different repo module, but it also means a resource sharing the cells' repo module
inherits every bind made to that module, whether or not the resource was meant to be tenanted.

## Options considered

### Option A — share the cells' repo module for shared tables

No longer possible. Upstream `ash_sqlite`'s `AshSqlite.Verifiers.VerifyTenantRepo` reports a
resource without `strategy :context` on a repo that implements `tenant_repo/2`, and the data layer's
`with_tenant_repo/4` raises `ArgumentError` on its first statement if it is compiled anyway. The
verifier's error is a Spark compile diagnostic, which fails a `--warnings-as-errors` build and is
only a warning otherwise.

What it did before, tested both ways in `ash_cell/test/non_tenanted_test.exs`: a non-tenanted
resource sharing the cells' repo module silently inherited bindings. A write issued while bound to
"acme" landed inside acme's cell file, with nothing raising, because the data layer had no way to
know a shared row was meant to be shared. Unbound, it instead failed with "could not lookup Ecto
repo ... not started," since an AshCell application never starts the named repo directly. Both
outcomes are wrong for a table meant to be shared.

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
  distinct from the cells' repo module, and AshSqlite enforces it. `AshCell.Resource`'s restriction
  to `strategy :context` depends on plain resources not needing anything AshCell-specific beyond a
  repo whose `write_transactions?/0` returns `true`.

## Evidence

- `ash_cell/test/non_tenanted_test.exs` — the own-module immunity, and "sharing the cells' repo
  module is refused" at compile time and on the first statement, with no row reaching acme's file.
  Before 2026-10-17 the same file pinned the silent shared-module failure instead.
- Upstream `ash_sqlite` `d200a69`: `lib/verifiers/verify_tenant_repo.ex`, and the `{false, true}`
  clause of `with_tenant_repo/4` in `lib/data_layer.ex`.
- Observed failure mode when sharing the repo module: a write bound to "acme" landing inside acme's
  cell file with nothing raising.
- Observed failure mode when unbound and sharing the repo module: "could not lookup Ecto repo ...
  not started."
- Commit: `7609603`.

## Notes

The two failure modes under Option A are worth keeping distinct: one is silently wrong (data lands
in the wrong tenant's file) and one is loudly wrong (a raised error). Only the silent one is
dangerous; it is also the one that motivated this ADR rather than the loud one.
