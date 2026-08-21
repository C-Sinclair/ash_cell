# ADR-02 — Bind in the data layer via a `tenant_binder` seam, not action hooks

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `ash_sqlite/lib/tenant_binder.ex` ·
`ash_cell/lib/ash_cell/binder.ex` · `ash_cell/lib/ash_cell/resource.ex`

## The decision

Bind a tenant's connection from inside the data layer, via a `tenant_binder` option in the fork's
`sqlite` DSL section, backed by a one-callback behaviour (`AshCell.Binder`). The data layer asks
the binder for a connection once per statement, from the process about to issue it, for every kind
of statement Ash can generate — reads, aggregates, atomic updates, atomic destroys, bulk writes.
`AshCell.Resource` reduces to setting `tenant_binder AshCell.Binder`; callers write plain
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

### Option D — `tenant_binder` seam in the data layer (chosen)

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
database-per-tenant layout would silently be another tenant's data. A mixed-tenant bulk batch also
raises. With no binder configured, behaviour is identical to unmodified `ash_sqlite`, so the
existing `ash_sqlite` suite was untouched.

## Consequences

- **What it rules out.** Binding from a caller-visible hook (preparation, change, or explicit
  wrapper) as the primary mechanism for `AshCell.Resource`. `with_tenant/2` survives only for code
  that touches a cell without going through a resource — `checkpoint/1`, raw Ecto, benchmarks.
- **What it makes worse.** The seam had to grow a `:usage` argument almost immediately, because
  "connection per statement" is not quite enough context for later needs (see
  [ADR-13](ADR-13-pool-size-one-and-cache.md), which relies on `:usage` to distinguish reads from
  writes for cache invalidation).
- **What stays open.** The self-correction on `require_atomic?`: the cost of the deleted
  transformer had been overstated. Ash's `:default_actions_require_atomic?` is `false`, so
  `defaults [update: ...]` actions were never on the atomic path anyway — the transformer only
  affected actions explicitly declaring `require_atomic? true`. A test resource
  (`update :rename do require_atomic? true end`) was added afterwards to actually exercise that
  path, which the original claim had not been tested against.
- **What now depends on it.** `AshCell.Resource` collapsing to a single DSL option;
  `ash_sqlite/lib/tenant_binder.ex`; `ash_cell/lib/ash_cell/binder.ex`; 11 tests in
  `ash_cell/test/binder_test.exs`; the upstreaming plan in
  [ADR-03](ADR-03-fork-ash-sqlite-narrowly.md).

## Evidence

- `ash_sqlite/lib/tenant_binder.ex`, `ash_cell/lib/ash_cell/binder.ex`,
  `ash_cell/lib/ash_cell/resource.ex`.
- 11 new tests in `ash_cell/test/binder_test.exs`; suite 128/0.
- Commits: `ash_cell` `1214a1e`; `ash_sqlite` `bcde253`, `91e4753`.
- Source constraints cited: `ash/lib/ash/actions/read/read.ex:88` and `:254`;
  `ash/lib/ash/actions/helpers.ex:25`; `ash_sqlite/lib/data_layer.ex:536`, `:609`, `:612`, `:624`,
  `:1409`, `:1561`, `:1621`, `:1650`, `:1775`, `:2252`, `:2302`; `ash/lib/ash/query/query.ex:4484`.

## Notes

Approach B is worth keeping in the record in full rather than summarising it away: it was not a
theoretical rejection, it was built, exercised, and only then found to miss two whole action
classes. The next person tempted to hook `around_transaction`/`around_action` globally should read
the three bullet points above before trying it again.
