# ADR-21 — Close does not wait for the connection; the rewrite path asks it to

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-09](ADR-09-snapshot-before-releasing-the-lease.md) · [ADR-12](ADR-12-whole-file-snapshots-on-a-schedule.md) · [`docs/design/DD-01`](../design/DD-01-cell-runtime.md)

## The decision

`AshCell.Manager.close/2` returns while the cell's SQLite connection is still shutting down.
A caller that is about to **rewrite the database file** must pass `await_repo?: true`, which
stops the repo synchronously via `AshCell.Cell.stop_repo/1` before the cell is terminated.
`AshCell.Replicator.restore/3` is the one caller that does.

## Context

`repo.start_link/1` runs inside `AshCell.Cell.init/1`, so the repo supervisor is *linked* to the
cell process. `DynamicSupervisor.terminate_child/2` waits for the cell's `terminate/2` and for
the cell process to die — it does not wait for the linked repo supervisor, which shuts down
afterwards, on its own schedule.

SQLite checkpoints the WAL into the `.db` as the last connection closes. So the sequence in
`restore/3` — close the cell, remove the WAL sidecars, write the snapshot bytes — could have the
dying connection's checkpoint land *on top of* the bytes just written, with pages belonging to
the database being replaced. `restore/3` then returns `{:ok, %{txid: n}}` over a database missing
everything it restored.

This surfaced as CI failing `test/object_store_test.exs:129` ("a destroyed local database is
restored from the object store") with the restored read coming back `[]`, twice, while the same
suite passed 5/5 locally and 11/11 under artificial CPU load. The mechanism above is **inferred
from the code, not reproduced locally** — that is the honest state of the evidence.

## Options considered

### Option A — leave it, and treat the test as flaky

Free. Costs a real bug: `restore/3` can report success over an empty database, which is the one
operation whose entire purpose is not losing data. Rejected.

### Option B — stop the repo synchronously in `Cell.terminate/2`

Correct everywhere with no caller opt-in, and the version built first. It makes every close and
every eviction pay a WAL checkpoint inline instead of letting it overlap.

Measured, and this is where the measurement was initially misread: the suite went from ~22s to
56–74s, which looked like a 3x regression. Re-measuring the *unchanged* code under the same
conditions gave 42.3s, and repeated runs of identical code spanned 42–74s. Most of the apparent
cost was run-to-run variance plus a MinIO bucket that had grown over the session. The real cost
is smaller than it first appeared and was never isolated.

Rejected anyway, on the argument rather than the number: an eviction under `max_resident`
pressure is on the hot path, a checkpoint is real fsync work, and nothing on that path needs the
guarantee.

### Option C — `await_repo?: true`, opted into by the rewrite path (chosen)

The one caller that rewrites the file waits; ordinary closes and evictions keep the old
behaviour. `AshCell.Cell.stop_repo/1` stops the repo and clears `repo_pid`, so `terminate/2` and
a second call are both no-ops.

Costs a flag that is easy to forget. That is why it is documented at both ends and why the
comment at the call site says it is load-bearing rather than defensive.

## Decision and why

Option C. The guarantee is only needed by code that touches the file behind the cell's back, and
that is rare and identifiable — `restore/3` today. Paying for it on every eviction would spend
hot-path latency on a promise almost no caller needs.

## Consequences

- **What it rules out.** No caller may assume the file is unheld the moment `close/2` returns.
  Anything that rewrites, moves, or truncates a cell's database must pass `await_repo?: true`.
- **What it makes worse.** A correctness property now depends on an option. A future rewrite path
  that forgets it gets the original bug back, silently, and only under load.
- **What stays open.** `File.rm` is not affected — unlinking a file another handle holds is fine
  on POSIX, and the dying connection then writes to an unlinked inode — so
  `Manager.handle_call({:delete, ...})` is left alone. That reasoning is not tested.
- The inferred mechanism is unproven locally. If CI keeps failing that test, this ADR is wrong
  and the next step is reproducing it rather than adding a second guess on top.

## Evidence

- `lib/ash_cell/cell.ex` — `repo.start_link/1` in `init/1`; `stop_repo/1` and the `:stop_repo`
  handler; `terminate/2`.
- `lib/ash_cell/manager.ex` — `close/2` and `await_repo_stopped/1`.
- `lib/ash_cell/replicator.ex` — `restore/3`, with the reason stated at the call site.
- CI runs 32523636764 and 32524120799, both failing `test/object_store_test.exs:129`.
- Timing, all on one workstation with a MinIO bucket accumulating across runs: unchanged code
  42.3s and up to 74s; Option B 56–74s; Option C 46.7s. The spread within identical code is
  wider than the difference between options, so none of these numbers isolate a cost. Treat them
  as evidence that the effect is *small*, not as a measurement of it.

## Notes

Found while fixing a separate, proven bug in the same area — `retry_start/2` spun three times
without yielding while waiting on an asynchronous registry cleanup, so a killed cell reported
`:cell_unavailable`. Both were failing the same CI job.
