# ADR-01 — Bind tenants per-process with `put_dynamic_repo/1`, not a query-context pid

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · `ash_cell/lib/ash_cell`

## The decision

Bind a tenant to a cell connection with `Ecto.Repo.put_dynamic_repo/1`, per OS process, using the
tenant id as the handle everywhere above Ecto. `AshCell.Registry` resolves that id to a pid; the
pid itself never leaves `bind/1`.

## Context

The original design spec assumed AshSqlite's query-context override
(`%{data_layer: %{repo: ...}}`) could carry a repo *instance* — a pid — letting a query name the
exact connection it wanted. This turned out to be false. The override is real, and AshSqlite does
consult it first, but both paths that use it invoke the result **as a module**: the read path
(`repo.all/2`, `ash_sqlite/lib/data_layer.ex:609`) and the write path (`repo.insert_all/3`, via
`AshSql.dynamic_repo/3`). Passing a pid there raises `ArgumentError: Modules (the first argument
of apply) must always be an atom`. The override selects a repo *module* (primary vs replica), not
an instance. Binding an instance is Ecto's job, and Ecto binds it per-process.

## Options considered

### Option A — query-context pid (the original assumption)

Would have let a query state its own connection independent of process. Costs nothing to write,
but does not work: both call sites `apply/3` the result as a module, so a pid raises immediately.
Abandoned once read against source.

### Option B — bare pid as the tenant handle

Unstable across process boundaries and not serialisable — cannot be carried in job args, sent
between nodes, or logged meaningfully.

### Option C — atom naming per tenant

Rejected: atoms are never garbage collected, and one atom per tenant leaks the atom table over the
lifetime of a fleet.

### Option D — a via-tuple

Tested. `put_dynamic_repo/1` guards its argument with `is_atom(dynamic) or is_pid(dynamic)`, so a
via-tuple raises at Ecto's boundary rather than working.

### Option E — tenant id as handle, resolved to a pid by a registry (chosen)

The tenant id is the handle everywhere above Ecto. `AshCell.Registry` resolves id → pid, and the
pid is used only inside `bind/1`, which calls `put_dynamic_repo/1` in the calling process. Costs an
extra registry lookup per bind, and the binding is now ambient rather than travelling with the
query — see Consequences.

## Decision and why

`put_dynamic_repo/1` is Ecto's own mechanism for per-process repo binding, and it is the only one
of the options that both works and keeps the tenant handle serialisable. The decision was settled
by reading `ash_sqlite/lib/data_layer.ex:609` and `AshSql.dynamic_repo/3` directly, not by
preference: both call sites `apply/3` their repo argument as a module, which rules out Option A
and B outright. Proven end to end by `ash_cell/test/probe_test.exs` (6 tests), which verifies
isolation by reading the underlying SQLite files directly, bypassing Ash. Commit: `903ee03`
("Prove per-tenant SQLite routing with a probe").

## Consequences

- **What it rules out.** A query can no longer name its own connection independent of the calling
  process. Anything that hands work to a different process — `Task.async`, `Ash.load` fan-out, an
  Oban job — loses the binding, because the binding lives in that process's dictionary via
  `put_dynamic_repo/1`. This drove [ADR-02](ADR-02-bind-in-the-data-layer.md),
  [ADR-17](ADR-17-bind-per-liveview-callback.md), and [ADR-18](ADR-18-tenant-in-job-args.md).
- **What it makes worse.** The query's stated tenant and the process's bound repo are two
  unreconciled values. `assert_bound!/0` only checks that *a* tenant is bound, never that it is
  *this* tenant. Concretely: bind clinic-7, then run code that queries `tenant: "clinic-9"`, and
  the code silently returns clinic-7's rows — nothing raises.
- **What stays open.** A fix was floated — a small `ash_sql` patch branching on `is_pid` to call
  the instance directly rather than through `apply/3`, letting the tenant travel with the query —
  and judged "a bigger upstream ask, might well be rejected." It was never filed. The mismatch
  above is real and unfixed.
- **What now depends on it.** `AshCell.Registry`, `AshCell.bind/1`, and every caller of
  `with_tenant/2` depend on the tenant id being the handle passed around, with pid resolution
  staying internal to bind.

## Evidence

- `ash_cell/test/probe_test.exs` — 6 tests, isolation verified by reading the SQLite files
  directly.
- `ash_sqlite/lib/data_layer.ex:609` — read path calls `repo.all/2`.
- `AshSql.dynamic_repo/3` — write path calls `repo.insert_all/3`.
- Commit `903ee03` — "Prove per-tenant SQLite routing with a probe".
- Not verified: the `is_pid` branch fix to `ash_sql` was never written or tested; the
  tenant/binding mismatch described above has no regression test.

## Notes

The rejected handle shapes (pid, atom, via-tuple) are worth keeping on record because each looks
plausible until tried: a pid looks natural until it needs to cross a process boundary, an atom
looks cheap until the atom table is considered, and a via-tuple looks like the "proper OTP" answer
until Ecto's own guard clause rejects it.
