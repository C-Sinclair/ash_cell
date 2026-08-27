# ADR-04 — Enable transactions behind an opt-in `write_transactions?` flag, with `BEGIN IMMEDIATE`

**Status:** accepted
**Last changed:** 2026-08-27 — the flag's schema default was silently defeating `AshCell.Resource`; see *How the default was carried* and its evidence.
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `ash_sqlite/lib/data_layer.ex` ·
`ash_cell/lib/ash_cell/resource/changes/carry_tenant.ex`

## The decision

Add a `write_transactions? true` option to the fork's `sqlite` DSL section, default `false` so upstream
behaviour is unchanged. When set, writes open with `BEGIN IMMEDIATE`, and
`prefer_transaction_for_atomic_updates?` stays `false` so a single-statement atomic update is not
wrapped or downgraded.

## Context

Upstream `ash_sqlite` declares `can?(_, :transact) → false`. This corrects an earlier constraint in
this project's own record that treated that as a limit of SQLite; SQLite is fully ACID, and the
`false` is a data-layer default, not a database limit. Upstream itself deleted transaction support
in `34e7a20 WIP`, right after `6fb4102 init: copy and gouge ash_postgres`; upstream's own docs name
the objection (SQLite's single write lock fails a lock upgrade immediately) but offer no way to
enable transactions where the objection does not apply.

## Options considered

### Option A — globally re-enable `can?(:transact) → true`

Tested, not just reasoned about. It broke 9 pre-existing `BinderTest` tests: every resource without
a tenant-carrying change raised "repo module not started," because `Ash.DataLayer.transaction/5`
fires *above* the data layer with no tenant in scope, before any per-statement bind happens.

### Option B — opt-in `write_transactions?` flag with `BEGIN IMMEDIATE` (chosen)

Cost: requires threading the tenant down to `transaction/4` through
`changeset.context[:data_layer]` (three different shapes need handling — see Decision and why),
and requires `in_transaction?/1` not to assume the repo module is a started, named process. Both
were built and tested rather than assumed.

## Decision and why

Enabled specifically because the only documented objection — contention semantics under SQLite's
single write lock — does not apply here: same-cell write contention already serialises on
`pool_size: 1` before it ever reaches SQLite's write lock, so there is only ever one writer per
cell asking for the lock at a time. **Writes use `BEGIN IMMEDIATE`.** A deferred read-then-write
must upgrade its lock, and SQLite fails that upgrade immediately regardless of `busy_timeout`.
Measured: two deferred read-then-write transactions racing produced one `Exqlite.Error` (even with
`busy_timeout: 2000`); the same pair with `BEGIN IMMEDIATE` both committed.

Three further points, each load-bearing and each established by test rather than assumed:

- **The tenant must reach `transaction/4` through `changeset.context[:data_layer]`.** Ash calls
  `transaction/4` above the data layer, and nothing in the transaction reason names a tenant.
  `AshCell.Resource.Changes.CarryTenant` puts it there. Three shapes had to be accepted:
  single-record paths pass `context[:data_layer]`, bulk paths pass the whole changeset context, and
  a read carries its query — `reason_tenant/1` handles all three.
- **`in_transaction?/1` must not assume the repo module is started.** Ash asks before opening a
  transaction, and a repo reached only via `put_dynamic_repo/1` has no named process, so
  `Ecto.Repo.in_transaction?/0` raises instead of answering.
- **A cell taken mid-transaction aborts it** rather than half-applying, because an uncommitted
  transaction on a closed connection cannot commit. This claim was originally stated as reasoning
  and then explicitly tested afterwards, on the grounds that "that is the right reasoning but it
  was untested, so it should not have been stated as fact." Tested including the drain path's
  `force: true` case.

A nested-savepoint caveat was found and left unresolved: `exqlite/lib/exqlite/connection.ex:314-340`
uses a single fixed savepoint name (`exqlite_savepoint`) rather than one appended per nesting level,
flagged as worth testing at depth ≥ 2 but not resolved here.

## How the default is carried, and how it silently was not

`AshCell.Resource` turns the flag on for the resources it is applied to, via
`AshCell.Resource.Transformers.BindTenant`, which sets `write_transactions?` only if the resource
has not set it — so an explicit `write_transactions? false` still wins.

**That mechanism broke, and it broke quietly.** The option was declared in the fork's schema with
`default: false`. Spark materialises a schema default into the section's `opts`, so
`Transformer.get_option(dsl, [:sqlite], :write_transactions?)` returned `false` rather than `nil`,
the transformer read that as "the user set it", and left it alone. Every `AshCell.Resource`
resource ran with transactions **off** while this ADR, `AshCell.Resource`'s own docs, and the
workspace notes all said they were on. Nothing raised: writes simply stopped being atomic, and a
failed multi-step action left its earlier steps behind.

`tenant_binder` was unaffected for one reason only — it has no schema default, so `get_option`
returned `nil` and the transformer set it. The two options sat two lines apart in the same
transformer with opposite outcomes.

The fix is in the fork and is narrow: **drop `default: false` from the `write_transactions?`
schema entry.** It was redundant — `AshSqlite.DataLayer.Info.write_transactions?/1` already passes
`false` as its own default (`lib/data_layer/info.ex:23`), so a resource that sets nothing still
reads `false` and upstream behaviour is bit-for-bit unchanged. Removing it is what restores the
distinction between *unset* and *set to false* that the transformer depends on.

The general trap, worth remembering beyond this option: **at transformer time a Spark schema
default is indistinguishable from an explicitly written value.** Any transformer that means "set
this unless the user did" can only work on an option with no schema default.

## Consequences

- **What it rules out.** Relying on upstream's default transaction behaviour anywhere — a resource
  must opt in with `write_transactions? true` to get transactional semantics at all.
- **What it makes worse.** `AshCell.Resource.Changes.CarryTenant` now exists purely to smuggle the
  tenant past a layer of Ash that was not designed to carry it, and `reason_tenant/1` has to handle
  three different changeset shapes to do it.
- **What stays open.** The nested-savepoint naming caveat, untested at depth ≥ 2. This directly
  informs [ADR-05](ADR-05-refuse-cross-cell-transactions.md) (nesting a transaction on another
  tenant is refused outright) and [ADR-06](ADR-06-own-repo-for-shared-tables.md) (shared tables get
  their own repo and their own transactions, not nested ones).
- **What now depends on it.** Any resource wanting transactional writes must set
  `write_transactions? true`; the drain path's `force: true` mid-transaction abort behaviour; the fork's
  `prefer_transaction_for_atomic_updates? → false` setting.

## Evidence

- **The silent regression, and the probe that found it.**
  `AshSqlite.DataLayer.Info.write_transactions?(AshCell.Test.BoundPatient)` returned `false`, and
  `Ash.DataLayer.data_layer_can?(BoundPatient, :transact)` returned `false`, on a resource using
  `AshCell.Resource`. Reading the raw option confirmed the cause rather than the symptom:
  `Spark.Dsl.Extension.get_opt(BoundPatient, [:sqlite], :write_transactions?, :UNSET, true)`
  returned `false`, not `:UNSET`, so the schema default was present in `opts`. `tenant_binder` on
  the same resource read `AshCell.Binder`, which is what narrowed it to "options with a schema
  default" rather than "the transformer did not run".
- **After dropping the schema default**, the same probe over four resources: a plain resource
  `false`, a `strategy :context` resource with nothing set `false`, a resource setting
  `write_transactions? true` explicitly `true`, and an `AshCell.Resource` resource `true`. The
  first two are the upstream-unchanged check; the third is the override still winning.
- **Suites after the change:** `ash_cell` 283 tests, 0 failures; `ash_sqlite` 289 tests, 0
  failures. Before it, `ash_cell` had 5 failures in `AshCell.TransactionTest` — four of them
  "a failing action leaves nothing behind", which is precisely the symptom of no transaction.

- Spike branch `spike/sqlite-transactions` on both repos, 11 probes passing.
- Feature branch suites: `ash_cell` 147/0; `ash_sqlite` 160/0 (154 existing + 6 new, upstream path
  unaffected).
- Measured lock-upgrade failure: deferred read-then-write racing pair → one `Exqlite.Error` with
  `busy_timeout: 2000`; the same pair under `BEGIN IMMEDIATE` → both commit.
- Commits: `ash_sqlite` `100b78b`; `ash_cell` `66b693a`, `dcf3329`, `7609603`.
- `exqlite/lib/exqlite/connection.ex:314-340` — fixed savepoint name, not level-appended.
- Not verified: behaviour of nested transactions at depth ≥ 2.

## Notes

The Option A failure (9 `BinderTest` tests breaking) is the concrete demonstration of why
[ADR-01](ADR-01-bind-tenants-per-process.md)'s "binding is ambient" consequence is not academic:
`Ash.DataLayer.transaction/5` is exactly the kind of call that fires above the data layer, with no
tenant in scope, that ADR-01 warned about.
