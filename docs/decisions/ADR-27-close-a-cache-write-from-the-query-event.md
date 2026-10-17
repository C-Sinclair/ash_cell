# ADR-27 — Close a read-cache write from the repo's query telemetry, not from a wrapper

**Status:** accepted
**Date:** 2026-10-17
**Deciders:** Conor Sinclair
**Relates to:** [ADR-02](ADR-02-bind-in-the-data-layer.md) · [ADR-13](ADR-13-pool-size-one-and-cache.md) · [ADR-26](ADR-26-count-in-flight-work-at-the-pool.md) · [`docs/design/DD-04-read-cache.md`](../design/DD-04-read-cache.md) · `lib/ash_cell/read_cache.ex` · `lib/ash_cell/binder.ex` · `scripts/tenant_repo_probe.exs`

## The decision

Open a write on `AshCell.ReadCache` from `AshCell.Binder.tenant_repo/2` whenever the data layer
asks for a cell with `type: :mutate`, and close it from a handler attached to the cell repo's
`[..., :query]` telemetry event. The handler closes the write on a `commit` or `rollback`, and on
any statement that runs outside a transaction. Opening erases the cell's projections, bumps its
epoch, and refuses publishes. Closing bumps the epoch again, after the commit. A non-`SELECT`
statement on a cell with no write open also bumps its epoch. Writers stay monitored, so a process
that dies with a write open still closes it.

## Context

[ADR-13](ADR-13-pool-size-one-and-cache.md) rests the cache's correctness on a bracket around every
write: erase before the statement, and erase again after the commit, so that a projection built
from pre-commit state cannot be published and survive. `AshCell.Binder.bind/3` was that bracket,
because the fork's `tenant_binder` wrapped each statement. Upstream's
`c:AshSqlite.Repo.tenant_repo/2` gives AshCell the "before" and nothing after. The second erase is
the half ADR-13 calls the one that matters.

## Options considered

### Option A — erase only before the write

`tenant_repo/2` with `:mutate` erases and bumps, and nothing happens after. Rejected: a reader can
capture the epoch after that bump and reach the connection before the writer does, because
`tenant_repo/2` returns before the writer asks the pool. It reads the pre-write state, the write
commits, and the reader's publish succeeds because nothing bumped again. Its stale value then
outlives the commit. ADR-13 records the same failure for `AshCell.transaction/2`, whose bracket
once closed before the commit.

### Option B — make a pre-commit projection unpublishable by reading a version from SQLite

Publish under a version read from the database, such as `total_changes()`, which counts every row
change on the connection, and a cell has one connection. Rejected on cost: a cache read would have
to ask SQLite whether the version had moved, which is a statement per `fetch/2`. The cache exists to
take reads off SQLite (17 µs a read against 0.04 µs in ADR-13's probe).

### Option C — close the write from the repo's query telemetry (chosen)

Ecto emits `[..., :query]` for every statement, including `begin`, `commit` and `rollback`. The
handler runs in the process that issued the statement, so the write it opened is in that process's
dictionary. The data layer has not yet restored the binding, so the cell can be read off the bound
instance. It runs after the commit is visible to other connections, and before the write returns to
its caller. The probe checked each of these properties rather than assuming it.

Costs: the handler runs for every statement on the repo, reads included, so its early exit for a
read is on the read path. A handler that raises is detached by `:telemetry` for good, which would
stop invalidation silently. And the event carries the repo module but not the instance, so a
statement on an instance the process has not bound is invisible to it.

## Decision and why

Option C. It is the only candidate that keeps both halves of ADR-13's bracket without code after the
statement and without a statement per cache read. What settled it was section B of the probe: for
every kind of Ash call the event arrived from the caller's own process with the cell's instance
bound, and at the `commit` event a separate connection already saw the new rows. Section E settled
the read-path cost, for a stand-in handler with the same early exit as the real one: one
process-dictionary read and one binary prefix match. A read paid 54.05 µs with it attached against
53.77 µs and 54.91 µs without it. The difference is inside run-to-run spread. The real handler was
not timed separately.

`repo.in_transaction?/0` is false at the `begin` event and true at statements inside the
transaction (probe section B). So the handler matches `begin`, `commit` and `rollback` by their text
and asks `in_transaction?/0` only for other statements.

## Consequences

- **What it rules out.** Treating a `SELECT` as a write, or anything else as a read. Reads are
  recognised by a leading `SELECT` and nothing else. Any other statement on a cell bumps its epoch:
  a `PRAGMA`, a lowercase raw query, the drain's checkpoint. That costs a cache miss. A projection
  whose own `build` issues such a statement bumps its epoch while building, so its publish is always
  refused and it is never cached.
- **What it makes better.** A raw write inside `AshCell.with_tenant/2` used to be invisible to the
  cache and had to call `invalidate/1`. It now runs on the bound instance and is caught.
- **What it makes worse.** Correctness now depends on a telemetry handler staying attached. The
  handler catches everything and logs rather than raising, so `:telemetry` has no reason to detach
  it. A bug that made it return early would still be silent, and only the integration tests would
  notice.
- **What stays open.** A statement on a cell instance the process has not bound, such as
  `Ecto.Adapters.SQL.query!/3` against a bare repo pid, does not invalidate. Neither does a restore
  that rewrites the file. Both must call `invalidate/1`, as before.
- **What now depends on it.** `AshCell.ReadCache.start_link/1` takes `repo:`, which
  `AshCell.Supervisor` passes. A cache started without it is invalidated only by explicit brackets.
  `AshCell.transaction/2` keeps its own `writing/2` bracket, since that transaction is opened below
  the data layer and its function has code after the commit.

## Evidence

- `scripts/tenant_repo_probe.exs`, section B, upstream `ash_sqlite` `d200a69`, ash 3.36.1. For
  `Ash.create!/3`: events `begin`, `INSERT`, `commit`, from the caller, instance bound throughout;
  `in_transaction?` false, true, false; rows seen by a second connection 3, 3, 4. An atomic update
  emitted one `UPDATE` outside any transaction. `Ash.bulk_create!/4` emitted `begin`, one
  `INSERT`, `commit`. A rolled-back `Ash.transaction/3` emitted `begin`, `INSERT`, `rollback`, and
  the second connection's count did not move. A create from another process delivered its events
  from that process.
- The same probe, section E: `Ash.read!/2` median of 5 runs of 2,000 calls. 53.77 µs with no
  handler, 54.05 µs with the early-exit handler, 54.91 µs with no handler again.
- `test/read_cache_integration_test.exs`: "a transaction Ash opens invalidates once it commits,
  not before", "a failed action leaves the cache publishable afterwards", and "a raw write on the
  bound cell invalidates it". The existing create, atomic update, destroy, bulk create, read, and
  per-tenant tests pass unchanged.
- Checked by breaking it on purpose. Not attaching the handler failed five of the twelve
  integration tests. Removing the `open_write/1` call from `tenant_repo/2` failed "a transaction
  Ash opens invalidates once it commits, not before".
- `Ecto.Adapters.SQL.log/5`, ecto_sql 3.14.0: the event metadata is `type`, `repo`, `result`,
  `params`, `cast_params`, `query`, `source`, `stacktrace`, `options`. It has no instance pid,
  which is why the cell is read off the process's binding.

## Notes

A write left open in a process without a following event, for example after a statement that raised
before reaching SQLite, refuses publishes for that cell until the process's next statement outside
a transaction or until it dies. That costs cache fills and not correctness. The test "a failed
action leaves the cache publishable afterwards" covers the common case, a rolled-back action.
