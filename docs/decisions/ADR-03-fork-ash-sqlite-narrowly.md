# ADR-03 — Fork `ash_sqlite` narrowly and keep it upstreamable; do not vendor it

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `ash_sqlite/`

## The decision

Keep the changes needed for AshCell as a narrow fork of `ash_sqlite`, tracked in `ash_sqlite/` with
commits matching the upstream project's own style, and aimed at becoming upstream PRs. Do not
vendor a renamed copy.

## Context

Upstream `ash_sqlite` declares `can?(_, :multitenancy) → false` (`lib/data_layer.ex:491` before the
fork), and upstream issue #127 asks for exactly the context-multitenancy support this project
needs on SQLite. Something had to change in `ash_sqlite` itself; the question was how much, and how
it should be packaged.

## Options considered

### Option A — a wrapper data layer delegating to `AshSqlite.DataLayer`

Feasible in principle, but the wrapper then owns re-implementing every callback it delegates,
which is most of the surface area of a data layer. Rejected before being built.

### Option B — pass the tenant to `AshSql.repo_opts/5` as a query rewrite

Tried first. It reached Ecto as a table **prefix** and raised "SQLite3 does not support table
prefixes." Fixed by making `set_tenant/3` a documented no-op instead: context multitenancy on
SQLite means one database per tenant, not a query rewrite — isolation comes from which file the
connection points at. This had to be written into the callback docs, because it is a trap for
anyone assuming AshPostgres semantics. Commit `ash_sqlite` `a8510fe`.

### Option C — vendor a renamed copy of `ash_sqlite`

Considered seriously when `mix hex.build` refused the git dependency ("Dependencies excluded from
the package (only Hex packages can be dependencies): ash_sqlite"). Measured before deciding:

- The fork diff is 534 insertions, 12 deletions across 5 commits, touching only
  `lib/data_layer.ex`, `lib/data_layer/info.ex`, a new `lib/tenant_binder.ex`, and tests. Only 12
  lines of *existing* upstream code are modified — two `can?/2` clauses plus call sites gaining a
  tenant argument.
- Vendoring means adopting roughly 8,486 lines of lib and 4,206 lines of tests to own 534 — a 16:1
  ratio.
- It would not even buy independence: `ash_sqlite` itself rides `ash_sql` for the hard parts (11
  call sites into `AshSql.Expr`, 8 into `Bindings`, plus `Atomics`/`Join`/`Query`), and nobody
  proposed forking `ash_sql` too.
- Publishing a renamed copy would require rewriting the `AshSqlite.*` namespace across roughly 60
  test files and the migration generator, foreclosing any future re-merge with upstream.
- A test rebase of the fork onto current upstream — including an upstream commit that itself
  touched multitenancy, the exact forked area — succeeded 5/5 commits, zero conflicts.

### Option D — narrow, upstreamable fork (chosen)

Cost: still a fork, still a git dependency `mix hex.build` will not package; the bridge option
below is needed if Hex publication becomes urgent.

## Decision and why

"The cost is real and the benefit is mostly imagined — a clean 5-commit rebase is not a fork in
trouble." The 16:1 ratio and the zero-conflict rebase are the numbers that decided it, not a
preference for forks in general. The bridge option, if Hex publication is needed sooner than
upstream review: publish the fork under its own name, version-pinned. The intended real fix is to
upstream `tenant_binder` and `transactions?` as PRs — both already default to current upstream
behaviour, which makes them a narrow ask. Revisit vendoring only if upstream declines the PRs *and*
the rebase starts conflicting; as of this ADR, neither has happened.

## Consequences

- **What it rules out.** Publishing `ash_sqlite` to Hex under the AshCell project's own namespace
  in the near term, since `mix hex.build` refuses a git dependency.
- **What it makes worse.** The project stays exposed to upstream drift until the PRs land or are
  declined; every AshCell release depends on the fork rebasing cleanly.
- **What stays open.** Whether upstream accepts `tenant_binder` and `transactions?` as PRs is
  unresolved — this ADR records the plan, not the outcome.
- **What now depends on it.** The convention that fork changes go in `ash_sqlite/`, as narrow
  commits matching the project's existing style, set here, is assumed by
  [ADR-02](ADR-02-bind-in-the-data-layer.md) and [ADR-13](ADR-13-pool-size-one-and-cache.md), both
  of which land their changes the same way.

## Evidence

- Diff shape: 534 insertions / 12 deletions across 5 commits, touching `lib/data_layer.ex`,
  `lib/data_layer/info.ex`, `lib/tenant_binder.ex`, and tests; 12 lines of existing upstream code
  modified.
- Vendoring cost: ~8,486 lines of lib, ~4,206 lines of tests, for a 16:1 adopt-to-own ratio.
- Rebase test: 5/5 commits, zero conflicts, onto a current upstream that includes an upstream
  multitenancy commit.
- `ash_sql` call-site count: 11 into `AshSql.Expr`, 8 into `Bindings`.
- Commit `a8510fe` — the table-prefix failure and the `set_tenant/3` no-op fix.
- Housekeeping finding: the fork's local `main` was 2 commits ahead of `origin/main` (`8fb72b3`,
  `91e4753`), meaning anyone cloning `ash_cell` standalone would silently get a fork missing the
  statement-usage argument.
- Not verified: whether upstream will accept the `tenant_binder` or `transactions?` PRs — no PR has
  been filed at the time of this record.

## Notes

The `mix hex.build` refusal is what surfaces vendoring as a live option again whenever it comes up;
this ADR is the place to point back to before re-running that argument, since the underlying
numbers (16:1, zero-conflict rebase) are unlikely to have changed unless the fork itself has grown.
