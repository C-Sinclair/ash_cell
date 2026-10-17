# ADR-26 — Count a cell's in-flight statements at its connection pool, not around each bind

**Status:** accepted
**Date:** 2026-10-17
**Deciders:** Conor Sinclair
**Relates to:** [ADR-02](ADR-02-bind-in-the-data-layer.md) · [ADR-13](ADR-13-pool-size-one-and-cache.md) · [ADR-17](ADR-17-bind-per-liveview-callback.md) · [ADR-21](ADR-21-close-does-not-await-the-connection.md) · `lib/ash_cell/registry.ex` · `lib/ash_cell/drain.ex` · `scripts/tenant_repo_probe.exs`

## The decision

Count the statements the data layer issues on a cell by asking the cell's connection pool, through
`DBConnection.get_connection_metrics/1`, how many callers hold or are queued for its one
connection. `AshCell.Registry.in_flight/1` does this, and `AshCell.Registry.active_binds/1` adds it
to the explicit binds from `AshCell.with_tenant/2` and the holders from `AshCell.bind_held/1`. The
drain and the eviction path wait on that sum as before. Explicit binds keep their ETS counter,
because `with_tenant/2` brackets its work and can decrement.

## Context

The fork's `tenant_binder` wrapped each statement, so `AshCell.Binder.bind/3` incremented the
cell's bind count before the statement and decremented it after. Upstream `ash_sqlite` replaced the
wrapper with `c:AshSqlite.Repo.tenant_repo/2`, which returns an instance and is not called again
when the statement ends. Commit `d200a69` deleted the last callback that ran afterwards. An
increment from `tenant_repo/2` would never be matched, the count would only grow, and a cell would
never look idle to a drain.

## Options considered

### Option A — keep counting per bind, and decrement from somewhere else

Increment in `tenant_repo/2` and decrement on the repo's query telemetry event. Rejected without
building, because the two do not pair. The probe recorded three `tenant_repo/2` calls for one
two-insert action (one to open the transaction, one per insert), against a `begin`, two inserts and
a `commit` on the event side. A statement that raises before reaching SQLite fires no event at all.
Any mismatch leaks a count, and a leaked count stalls every drain of that cell until its grace
deadline.

### Option B — a per-process "statement pending" row, cleared by the next event

Same pairing problem, moved into ETS. A process that dies between the row and the event leaves the
row behind with nothing to clear it, which is the leak again.

### Option C — ask the connection pool (chosen)

A cell's repo is started with `pool_size: 1` ([ADR-13](ADR-13-pool-size-one-and-cache.md)), so
every statement on the cell checks that one connection out and every waiter sits in the pool's
queue. The pool already knows the number the drain needs. A transaction holds the connection from
`BEGIN` to `COMMIT`, so it counts for its whole length, which is what the old bracket around
`transaction/4` gave. Nothing is incremented, so nothing can leak.

Costs: a `GenServer.call` to the pool per question, and the eviction path asks once per resident
cell when the node is full. And it cannot see a statement before it asks the pool for the
connection. The Evidence section measures both.

## Decision and why

Option C, because it is the only candidate whose count cannot drift: the pool decrements when the
connection comes back, whatever happened in between. Options A and B each need a matched pair of
events that the probe showed do not exist.

## Consequences

- **What changes in the guarantee.** A statement is counted from the moment it asks the pool for
  the connection, not from the moment its cell was resolved. Between those two points it is
  invisible to a drain. The probe measured that window at a median of 2.3 µs and a maximum of
  25.9 µs for `Ash.read!/2`. The old count had a window of the same kind, between
  `AshCell.Registry.bound/1` checking `closing?/1` and incrementing, but it was a few instructions
  wide. A statement that loses this race runs against a repo that is shutting down, and it fails
  with `could not lookup Ecto repo ... not started`. It does not run against another cell.
- **What it makes worse.** `active_binds/1` now makes a call to a pool process. A pool that is
  wedged would block the caller, because DBConnection asks with an `:infinity` timeout.
- **What it rules out.** Widening `pool_size` without revisiting this. `in_flight/1` reads
  `1 - ready_conn_count`, which is only "the connection is in use" when there is one connection.
- **What stays open.** An idle-connection ping briefly checks the connection out, and reads as one
  in-flight statement. A drain polls every 50 ms, so this delays it rather than misleading it. This
  was not observed in a test.
- **What now depends on it.** `AshCell.Drain.await_quiescence/2`, `AshCell.Manager.close/2`, and
  `AshCell.Manager`'s eviction, which skips any cell whose `active_binds/1` is non-zero.
  `AshCell.Cell.init/1` registers its repo instance with `AshCell.Registry.put_repo/2` so the pool
  can be found from the cell key.

## Evidence

- `scripts/tenant_repo_probe.exs`, section A, against upstream `ash_sqlite` `d200a69`, ash 3.36.1,
  OTP 28: the metric read 0 on an idle pool, 1 with an `Ash.transaction/3` open and nothing else, 4
  with three `Ash.read!/2` calls queued behind that transaction, 0 once all had finished, and 1
  while a recursive-CTE statement ran outside any transaction. Asking cost 0.71 µs on an idle pool
  (median of 5 runs of 1,000). One `Ash.read!/2` end to end cost 51 µs on the same run.
- The same probe, section D: the window between `tenant_repo/2` returning and the pool checkout,
  measured as the time to the query event minus the event's own queue, query and decode times.
  `Ash.read!/2` median 2.3 µs, p99 17.5 µs, max 25.9 µs; `Ash.count!/2` median 3.9 µs, p99 12.9 µs,
  max 21.0 µs; 1,000 calls each. Because the subtraction leaves in the work after the query, these
  are upper bounds.
- The same probe, section C: three `tenant_repo/2` calls for one two-insert action, all `:mutate`.
- `test/drain_test.exs`: "a transaction the data layer opened counts, though nothing bound the
  cell", "a statement queued behind the open transaction counts too", and "statements leave
  nothing counted once they finish".
- `DBConnection.ConnectionPool.handle_call(:get_connection_metrics, ...)`, db_connection 2.10.2.
- Not verified: the cost of the eviction path's per-cell question on a full node. It is one pool
  call per resident cell, and `max_resident` defaults to 256.

## Notes

The window could be narrowed by having `AshCell.Manager.close/2` require two quiet readings one
poll apart. That would cost 50 ms on every non-forced close, and it was not done. It would still be
a check-then-act race, only a less likely one.
