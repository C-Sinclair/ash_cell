# ADR-28 — Read the bound cell off Ecto's binding, not a process-dictionary entry beside it

**Status:** accepted
**Date:** 2026-10-17
**Deciders:** Conor Sinclair
**Relates to:** [ADR-01](ADR-01-bind-tenants-per-process.md) · [ADR-05](ADR-05-refuse-cross-cell-transactions.md) · [ADR-07](ADR-07-opaque-cell-keys.md) · [ADR-26](ADR-26-count-in-flight-work-at-the-pool.md) · `lib/ash_cell.ex` · `lib/ash_cell/registry.ex` · `scripts/tenant_repo_probe.exs`

## The decision

`AshCell.bound_cell/0` reads the repo instance Ecto has bound in the calling process
(`repo.get_dynamic_repo/0`) and maps it back to its cell key through `AshCell.Registry`, where each
cell registers its instance when it starts. `AshCell.assert_bound!/0` and `AshCell.transaction/2`'s
cross-cell check use it. The process-dictionary entry that explicit binds keep is now only the
cell that `AshCell.bind/1` counted, so that `AshCell.restore/1` releases the same count.

## Context

`bound_cell/0` returned a process-dictionary entry that `AshCell.bind/1` set and
`AshCell.restore/1` put back. `AshCell.Binder.bind/3` did the same around every data-layer
statement, so inside an action's transaction the entry named the action's cell. That is what lets
`AshCell.transaction/2` refuse to open a transaction on cell A from inside an `after_action` hook
running in a transaction on cell B ([ADR-05](ADR-05-refuse-cross-cell-transactions.md)).

Upstream's `c:AshSqlite.Repo.tenant_repo/2` binds and restores the instance itself. If
`tenant_repo/2` set the entry, nothing would put it back after the statement. If it did not, the
entry would say nothing inside an action's transaction, and the cross-cell check would pass a
nesting it exists to refuse.

## Options considered

### Option A — set the entry in `tenant_repo/2` and never restore it

Rejected. After any statement the entry would name a cell the process is no longer bound to.
`test/binder_test.exs` "nothing is left bound to the caller afterwards" asserts the opposite.

### Option B — derive it from Ecto's binding (chosen)

The data layer binds the instance for each statement and for the whole of a transaction it opens,
and restores the previous one afterwards. The binding is therefore already a faithful record of
which cell the process is on, at every point. The probe showed the binding inside an
`Ash.transaction/3` is the cell's instance and the binding after a statement is the repo module
again. One registry lookup turns the instance into its cell key.

Cost: a binding to a cell that has since stopped maps to nothing, because its instance's
registration went with it. `bound_cell/0` then answers `nil` where it used to answer the key. And
it needs the repo module, which it gets from `AshCell.Manager`.

## Decision and why

Option B. Nothing above the data layer has to keep the answer in step with the binding, because it
is read from the binding. That is the same reason the binding moved into the data layer in
[ADR-02](ADR-02-bind-in-the-data-layer.md).

## Consequences

- **What changes in the guarantee.** A process bound to a cell whose instance has stopped gets
  `nil` from `bound_cell/0`, and `assert_bound!/0` raises "no AshCell tenant is bound". It used to
  return the key and fail on the next statement instead. Either way no statement runs.
- **What it makes better.** `bind_held/1` no longer writes the entry, so `unbind/0` after a hold
  no longer releases a count that `bind_held/1` never took.
- **What stays open.** `bound_cell/0` now makes a call to `AshCell.Manager` for the repo module.
- **What now depends on it.** `AshCell.transaction/2`'s cross-cell refusal inside an action's
  transaction, `AshCell.assert_bound!/0`, `AshCell.Job`, and `AshCell.Cell.init/1` registering its
  instance with `AshCell.Registry.put_repo/2`.

## Evidence

- `scripts/tenant_repo_probe.exs`, section C: the binding was the repo module before and after an
  `Ash.create!/3`, and the cell's instance pid inside an `Ash.transaction/3`.
- `test/transaction_test.exs` "the transaction Ash opens for an action / is opened on the action's
  own cell": an `after_action` hook reports `AshCell.bound_cell()` as `"acme"` and
  `AshCell.in_transaction?()` as true.
- `test/transaction_test.exs` "opening a transaction on another tenant inside one is refused",
  `test/binder_test.exs` "the binding is released", and `test/context_test.exs` "nesting and
  restoration" pass unchanged.
- `test/context_test.exs` "a binding to a cell that has since closed reports no cell".
