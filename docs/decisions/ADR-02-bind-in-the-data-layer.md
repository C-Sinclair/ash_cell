# ADR-02 — Bind in the data layer, through the repo's `tenant_repo/2`, not action hooks

**Status:** accepted
**Last changed:** 2026-10-17 — the seam is upstream's `c:AshSqlite.Repo.tenant_repo/2` on the repo, not the fork's `tenant_binder` DSL option. Upstream's callback returns an instance and does not wrap the statement, so the three things AshCell did after each statement moved: see [ADR-26](ADR-26-count-in-flight-work-at-the-pool.md), [ADR-27](ADR-27-close-a-cache-write-from-the-query-event.md), and [ADR-28](ADR-28-read-the-bound-cell-off-the-ecto-binding.md).
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `ash_cell/lib/ash_cell/binder.ex` ·
`ash_cell/lib/ash_cell/repo.ex` · `ash_cell/lib/ash_cell/resource.ex`

## The decision

Bind a tenant's connection from inside the data layer. Upstream `ash_sqlite` asks the resource's
repo for an instance through `c:AshSqlite.Repo.tenant_repo/2`, once per statement, from the process
about to issue it, for every kind of statement Ash can generate: reads, aggregates, atomic updates,
atomic destroys, bulk writes, and opening a transaction. It binds the instance with
`put_dynamic_repo/1` and restores the previous binding afterwards. `use AshCell.Repo` makes a repo
module answer that callback with `AshCell.Binder.tenant_repo/2`. Callers write plain
`Ash.read!(Patient, tenant: t)` with no wrapper.

## Context

[ADR-01](ADR-01-bind-tenants-per-process.md) established that tenant binding is ambient — it lives
in the calling process's dictionary — so it does not survive a process boundary. That leaves the
question of *where above or in the stack* to bind before a statement runs, and it took two built
(not merely proposed) approaches failing before this seam was found.

## Options considered

### Option A — callers wrap everything in `AshCell.with_tenant/2`

Every call site binds explicitly. Rejected as unergonomic: the caller has to get it right
everywhere, "including in the places with no obvious entry point — a Task, a load fan-out, a
job."

### Option B — global preparation and change installing Ash hooks

Built: `AshCell.Resource` with `preparations/bind_tenant.ex`, `changes/bind_tenant.ex`, a
transformer, and a verifier, installing `Ash.Query.around_transaction/2` and
`Ash.Changeset.around_action/2` hooks. Then deleted, for three reasons checked against source:

- Preparations run inside `Ash.Query.for_read/4`, which for an unvalidated query Ash calls *after*
  it has already consumed the query's `around_transaction` hooks (`ash/lib/ash/actions/read/read.ex:88`
  vs `:254`) — the hook silently never runs.
- `Ash.count/2` never enters `Ash.Actions.Read` at all, so aggregates get no hook whatsoever.
- Ash calls `atomic/3` instead of `change/3` when it can build one statement, and
  `Ash.Actions.Helpers` diverts any changeset carrying a non-empty `around_transaction` off the
  batchable/atomic path (`ash/lib/ash/actions/helpers.ex:25`). A change-based hook therefore always
  forced `require_atomic? false`.

The failure mode was "could not lookup Ecto repo ... not started" — an error, not silently wrong
data, but too silent for daily use.

### Option C — bind inside the data layer's `set_tenant/3`

Rejected without building: there is no matching release callback, so a bind there would never
decrement `Registry.bound/1` and would permanently starve drain.

### Option D — a seam in the data layer (chosen, first as the fork's `tenant_binder`)

This was first built in the fork as a `tenant_binder` option in the `sqlite` DSL section, backed by
a one-callback behaviour whose `bind/3` wrapped each statement. Upstream later took the same idea
in a different shape: a callback on the repo that returns an instance, with the data layer doing
the bind and the restore itself. AshCell now uses upstream's, and the paragraph below records how
the fork's version was built.

The data layer asks the binder for a connection once per statement, from the process about to
issue it. `update_query/4` and `destroy_query/4` already hold `changeset.tenant` in the same
process at the moment the repo is resolved (`ash_sqlite/lib/data_layer.ex:1650`, `:1775`).
`set_tenant/3` — previously a documented no-op at `data_layer.ex:536` — now stashes the tenant for
`run_query`/`run_aggregate_query` to read via
`query.__ash_bindings__.context[:private][:tenant]`, which Ash already populates
(`ash/lib/ash/query/query.ex:4484`), so no Ash change was needed. Cost: it required later extending
the seam to carry a `:usage` argument (`:read | :write | :transaction`), because only the data
layer knows which kind of statement is about to run — read call sites `:612`, `:624`; write call
sites `:1409`, `:1561`, `:1621`; transactions `:2252`; seam at `bind_tenant/3`, `:2302`.

## Decision and why

The data layer is the only seam that sees every path Ash can take to a statement — including the
two paths (`Ash.count/2`, the atomic path) that a hook-based approach was shown, against source, not
to reach. That is the argument, not a preference: Option B was built, its three failure points were
each traced to specific lines, and it was deleted rather than patched because patching would still
leave `Ash.count/2` uncovered. The seam fails closed: a tenanted statement arriving with no tenant
raises rather than running on whatever repo the process happens to hold, which in a
database-per-tenant layout would silently be another tenant's data. Upstream's version keeps that
property, and `AshCell.Binder.tenant_repo/2` raises `AshCell.CellUnavailableError` rather than
return an instance it could not resolve.

Upstream's version has no callback after the statement. The fork's `bind/3` used the time after a
statement to decrement the drain's in-flight count, to close the read cache's write bracket, and to
restore the process's bound cell key. Each now has its own mechanism, recorded in
[ADR-26](ADR-26-count-in-flight-work-at-the-pool.md), [ADR-27](ADR-27-close-a-cache-write-from-the-query-event.md),
and [ADR-28](ADR-28-read-the-bound-cell-off-the-ecto-binding.md).

## Consequences

- **What it rules out.** Binding from a caller-visible hook (preparation, change, or explicit
  wrapper) as the primary mechanism for `AshCell.Resource`. `with_tenant/2` survives only for code
  that touches a cell without going through a resource — `checkpoint/1`, raw Ecto, benchmarks.
- **What it makes worse.** The seam had to grow a `:usage` argument almost immediately, because
  "connection per statement" is not quite enough context for later needs. Upstream's callback
  carries the same distinction as `context.type`, `:read` or `:mutate`, and
  [ADR-27](ADR-27-close-a-cache-write-from-the-query-event.md) relies on it to open a cache write.
- **What stays open.** The self-correction on `require_atomic?`: the cost of the deleted
  transformer had been overstated. Ash's `:default_actions_require_atomic?` is `false`, so
  `defaults [update: ...]` actions were never on the atomic path anyway — the transformer only
  affected actions explicitly declaring `require_atomic? true`. A test resource
  (`update :rename do require_atomic? true end`) was added afterwards to actually exercise that
  path, which the original claim had not been tested against.
- **What now depends on it.** `AshCell.Repo`, `AshCell.Binder.tenant_repo/2`, and the tests in
  `ash_cell/test/binder_test.exs`. `AshCell.Resource` no longer sets anything; it is a
  compile-time check for `strategy :context`.

## Evidence

- Upstream `ash_sqlite` `d200a69`: `c:AshSqlite.Repo.tenant_repo/2` in `lib/repo.ex`, and
  `with_tenant_repo/4` and `bind_tenant_repo/5` in `lib/data_layer.ex`. Commit `d200a69` deleted
  `c:AshSqlite.TenantRepo.with_repo/4`, the last callback that wrapped a statement.
- `scripts/tenant_repo_probe.exs`, section C: the binding is the repo module before and after a
  statement, and the cell's instance inside an `Ash.transaction/3`.
- The fork's version: `ash_sqlite/lib/tenant_binder.ex` and the earlier
  `ash_cell/lib/ash_cell/binder.ex`, at `ash_cell` `07a25e9`.
- 11 new tests in `ash_cell/test/binder_test.exs`; suite 128/0.
- Commits: `ash_cell` `1214a1e`; `ash_sqlite` `bcde253`, `91e4753`.
- Source constraints cited, at the ash and fork versions read in 2026-08: `ash/lib/ash/actions/read/read.ex:88` and `:254`;
  `ash/lib/ash/actions/helpers.ex:25`; `ash_sqlite/lib/data_layer.ex:536`, `:609`, `:612`, `:624`,
  `:1409`, `:1561`, `:1621`, `:1650`, `:1775`, `:2252`, `:2302`; `ash/lib/ash/query/query.ex:4484`.

## Notes

Approach B is worth keeping in the record in full rather than summarising it away: it was not a
theoretical rejection, it was built, exercised, and only then found to miss two whole action
classes. The next person tempted to hook `around_transaction`/`around_action` globally should read
the three bullet points above before trying it again.
