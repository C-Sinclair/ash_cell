# ADR-03 — Depend on upstream `ash_sqlite`; the narrow fork is retired

**Status:** reversed
**Last changed:** 2026-10-17 — upstream `ash_sqlite` main now supports `strategy :context` through a tenant repo (`c:AshSqlite.Repo.tenant_repo/2`) and transactions through `c:AshSqlite.Repo.write_transactions?/0`. AshCell pins upstream at `d200a69` and no longer depends on the fork. The fork's API did not land as written: upstream's callback returns an instance rather than wrapping the statement, which is why [ADR-26](ADR-26-count-in-flight-work-at-the-pool.md), [ADR-27](ADR-27-close-a-cache-write-from-the-query-event.md) and [ADR-28](ADR-28-read-the-bound-cell-off-the-ecto-binding.md) exist.
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `mix.exs`

## The decision

Depend on upstream `ash-project/ash_sqlite`, pinned to a git ref until a release contains
`tenant_repo/2`. Do not fork it and do not vendor it. When AshCell needs something upstream does
not have, adapt AshCell to upstream's shape first, and propose a narrow upstream change only when
that is not possible.

From 2026-08-21 until 2026-10-17 the decision was the opposite: keep a narrow fork with commits in
upstream's style, aimed at becoming upstream PRs. That fork is what upstream's tenant repo grew out
of, and the reasoning that chose it over vendoring follows.

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

### Option E — upstream `ash_sqlite`, pinned to a ref (chosen since 2026-10-17)

Upstream merged context multitenancy as `c:AshSqlite.Repo.tenant_repo/2` (#224), then moved
`write_transactions?` from the resource DSL onto the repo and deleted `with_repo/4` (`d200a69`).
Costs: a git dependency until a release, so `mix hex.build` still refuses AshCell; and no callback
after a statement, which AshCell's binder had used for three things.

## Decision and why

Since 2026-10-17: upstream, because the fork existed to get these features upstream and they are
there. Carrying a fork whose API upstream chose not to take would keep AshCell on an interface
nobody else maintains. The redesign that upstream's shape forced on `AshCell.Binder` is recorded
in ADR-26, ADR-27 and ADR-28.

The original reasoning, for the fork over vendoring:

"The cost is real and the benefit is mostly imagined — a clean 5-commit rebase is not a fork in
trouble." The 16:1 ratio and the zero-conflict rebase are the numbers that decided it, not a
preference for forks in general. The bridge option, if Hex publication is needed sooner than
upstream review: publish the fork under its own name, version-pinned. The intended real fix is to
upstream `tenant_binder` and `write_transactions?` as PRs — both already default to current upstream
behaviour, which makes them a narrow ask. Revisit vendoring only if upstream declines the PRs *and*
the rebase starts conflicting; as of this ADR, neither has happened.

## Consequences

- **What it rules out.** Changing `ash_sqlite` from this repo. A need upstream does not meet is
  met in AshCell or proposed upstream.
- **What it makes worse.** AshCell is pinned to an unreleased upstream commit, so it still cannot
  be published to Hex, and a bump can bring API changes with it: `d200a69` is titled "spike out
  simplifying multitenancy".
- **What stays open.** When upstream releases `tenant_repo/2`, and whether its shape changes
  before then.
- **What now depends on it.** `AshCell.Repo`, `AshCell.Binder.tenant_repo/2`, and every demo's
  cell repo.

## Evidence

- Upstream `ash_sqlite` `3ef9388` ("support `strategy :context` multitenancy via a tenant repo",
  #224) and `d200a69` ("spike out simplifying multitenancy via moving config to repo"), read at
  `upstream/main`. #224 was opened from this fork's `tenant_binder` work, and its description
  says so.

The original evidence, for the fork over vendoring:


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
- Not verified: whether upstream will accept the `tenant_binder` or `write_transactions?` PRs — no PR has
  been filed at the time of this record.

## Notes

The `mix hex.build` refusal is what surfaces vendoring as a live option again whenever it comes up;
this ADR is the place to point back to before re-running that argument, since the underlying
numbers (16:1, zero-conflict rebase) are unlikely to have changed unless the fork itself has grown.
