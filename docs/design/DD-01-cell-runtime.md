# DD-01 — The cell runtime

**Status:** built
**Date:** 2026-08-21
**Decisions:** [ADR-09](../decisions/ADR-09-snapshot-before-releasing-the-lease.md), [ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md), [ADR-17](../decisions/ADR-17-bind-per-liveview-callback.md), [ADR-07](../decisions/ADR-07-opaque-cell-keys.md)
**Lands in:** `lib/ash_cell/manager.ex`, `lib/ash_cell/registry.ex`, `lib/ash_cell/cell.ex`, `lib/ash_cell/drain.ex`, `lib/ash_cell/holders.ex`, `lib/ash_cell/supervisor.ex`

## What this is

The runtime that turns a cell key into a live SQLite connection and back again: `Manager`
starts, finds and evicts `Cell` processes; `Registry` maps cell keys to pids and counts who is
mid-query; `Drain` hands cells over on shutdown instead of dropping them.

## What this proves

- A cell activates on first touch and stays resident until evicted, quarantined, or drained.
- Residency is bounded (`max_resident`), and eviction is LRU, not unbounded growth.
- A quarantined cell refuses to serve rather than reopening a file it may not own.
- A draining node hands every resident cell over in bounded time, releasing leases so a
  successor does not wait out a TTL.
- Quiescence tracking does not put a bottleneck in front of every query.

## Why it needs a cell

This is the runtime the rest of the library rests on, not a demonstration of a boundary
choice. Single-writer-per-file is only real if something in the process owns the connection
for the file's lifetime, evicts it under memory pressure, and can prove nobody is using it
before handing it to a successor. That something is `Manager` plus `Registry` plus `Cell`.

## Non-goals

- No cross-cell coordination. Everything here is keyed by cell key, never by tenant — the
  resolution from Ash's tenant to a cell key happens once, at `AshCell.bind/1`, before any of
  this runs ([ADR-07](../decisions/ADR-07-opaque-cell-keys.md)).
- No query-level visibility. Queries go straight to the repo instance, not through the `Cell`
  process, so this runtime never sees an individual statement.
- No admission control for cold restores after a mass eviction. That is on the open list.

## Data model

Everything here is process state, not persisted rows:

- `Manager` holds fleet configuration (`repo`, `dir`, `key_for`, `migrator`, `max_resident`,
  `store`, `owner`, `snapshot`) plus `lru`, `quarantined`, `leases`, `shipping`, and `sealed?`.
- `Registry` is a `Registry` (cell key → pid) plus a public ETS counter table for binds.
- `Cell` holds `cell_key`, `repo`, `repo_pid`, `path`, `opened_at`, `schema_version`, `store`,
  `policy`, `last_ship_at`, `queries`, `ships`.

Nothing here crosses the global-store/cell boundary; there is no global store in this doc.

## Trade-offs

- **ETS counter, not `GenServer.call`, for binds.** A call in front of every tenanted query
  would put one process ahead of the whole fleet's read and write path. The counter costs a
  bind and unbind per statement but nothing that serialises.
- **Queries bypass the `Cell` process entirely.** Callers bind the repo instance directly with
  `put_dynamic_repo/1`; the `Cell` GenServer is not on the query path at all. This is why
  quiescence has to be tracked separately rather than inferred from the process's mailbox.
- **LRU eviction closes a connection, not the data.** The file stays on disk; eviction only
  drops the connection and its page cache. A cold reactivation pays a fresh open plus the WAL
  replay, not a restore.

## Measurements this must produce

No throughput numbers are owed by this layer specifically; its measured claims are behavioural,
each with a stated shape rather than a number:

- Drained node vs killed node, same tenant: killed node's successor observes `{:held_by,
  "node-a"}` and is locked out until the lease TTL; drained node's successor claims
  immediately. One demo run recorded "drained 3 cell(s) in 1ms; leases released."
- Quiescence wait is bounded, not unbounded — the parameter that triggers the cliff is the
  wait deadline itself: past it, a forced close interrupts whatever is mid-read rather than
  waiting for a `SIGKILL` that would lose the snapshot too.

## Staging

1. `Manager`/`Registry`/`Cell` built first: activation, LRU eviction, `max_resident`.
2. Drain added on top ([ADR-09](../decisions/ADR-09-snapshot-before-releasing-the-lease.md)):
   seal → quiesce → per cell: checkpoint → snapshot → release lease → close, with 24 new tests
   (6 against real MinIO) taking the suite from 83 to 94.
3. Fail-closed on a refused shipment added
   ([ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md)): quarantine the cell
   key, force-close the process, drop the lease, all together — quarantine alone or close
   alone each leave a reactivation path.
4. `AshCell.Holders` added for LiveView sessions
   ([ADR-17](../decisions/ADR-17-bind-per-liveview-callback.md)): a duplicate-key `Registry`,
   self-cleaning via monitors, so quiescence means "nobody is looking at this" rather than "no
   query is executing this millisecond."

## Where it stops

- Eviction and drain manage the connection, not correctness of concurrent writers to the same
  cell — that rests on `pool_size: 1` plus SQLite's own locking, described in
  DD-02 and DD-03.
- Quarantine and force-close stop a node from serving a cell it has lost; they do nothing for
  a partitioned node that has *not yet* discovered it lost the cell (see DD-02's fencing and
  the read-staleness note in ADR-14).
- There is no cross-cell fan-out here — draining and quarantine both operate one cell at a
  time.

## Open risks

- `Manager.fence/1` is called from inside an unlinked `Task` spawned by `Cell`, and that task
  then closes the cell that spawned it — structurally similar to a race that has already bitten
  once elsewhere in this project, not yet observed here across 12 runs, unresolved.
- Thundering herd on node loss: mass eviction followed by mass cold reactivation has no
  admission control.
- Lazy per-cell migration failure is a single-tenant outage; there is no fleet-wide migration
  gate before serving.
