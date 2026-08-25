# branch — a branching SQLite service

**Cell cut:** one cell per **branch**.

Provision a database, get a SQL console against it, snapshot it, cut a named branch from any
snapshot, write to the branch and the parent independently, then promote the branch — or watch
the promotion be refused, which is the more interesting outcome.

This is the copy-on-write branching that Neon is known for, built on cells. It is here because
branching falls almost entirely out of the design rather than being added to it: a cell is one
file, `AshCell.Replicator` already writes immutable snapshots keyed by txid, and
[ADR-07](../../docs/decisions/ADR-07-opaque-cell-keys.md) already says a cell key is opaque. So
`db:acme@main` branching to `db:acme@pr-1234` needs no new routing concept, and the branch gets
its own file, its own lease, and its own txid namespace for free.

## What this proves

- **A branch is genuinely isolated, in both directions.** The console runs a statement against a
  branch and its parent side by side; writes on one do not appear in the other, because they are
  two files with two connections. Not a filtered view of one table, not a row-level tenant
  column — two databases.
- **A branch is cut from a *point*, not from "now".** Snapshots are immutable and keyed by txid,
  so `from: 209` is a real address. Asking for a txid that never shipped resolves *down* to the
  nearest snapshot and says it did rather than silently landing somewhere else.
- **A branch inherits no part of its parent's fencing state.** It is a different cell key, so it
  takes its own lease and starts its own txid namespace at 1. Neither cell can claim a txid the
  other has written, which is [ADR-08](../../docs/decisions/ADR-08-fence-by-shared-txid.md)
  working unchanged on a construct it was not designed for.
- **Promotion is fast-forward or refusal, and the refusal is precise.** If the parent has been
  written to since the branch was cut, the merge is refused with both content digests. See
  [ADR-23](../../docs/decisions/ADR-23-merge-by-fast-forward-or-refuse.md).
- **A merge is durable, not just local.** The promoted state is shipped before the merge reports
  success. Deleting the parent's local file and restoring from the object store gets the merged
  database back.

## Where it stops

Read this section before quoting any of the above.

- **There is no merge of two diverged branches, and there will not be one here.** Two conflicting
  `UPDATE`s on one row have no reconciliation that is not a domain rule, so the library refuses
  rather than picking a winner. A branch left open while its parent keeps serving becomes
  unmergeable and must be re-cut. **Long-lived branches are not a supported shape.** This is also
  what Neon does — its branches are rehearsal environments, and what gets promoted is a migration
  through git, not a reconciliation of rows.
- **Branching is a whole-file copy, so it is O(size), not O(1).** Neon's constant-time branching
  is its page server: LSN-addressed copy-on-write pages so a 500 GB database branches without
  copying. Nothing here does that, and rebuilding it is a storage engine, not a demo. Cells are
  small by design, so whole-file copying is the right answer *at this size* — but it is a
  different answer, and the storage cost is unbounded: a hundred branches is a hundred copies,
  with no deduplication.
- **Branch points are snapshot boundaries, not instants.** "What did this look like at 14:32" is
  answered to within a snapshot interval. This demo ships every 5 s to make the history visible,
  which is not a production cadence.
- **No authorisation.** Forking a database produces a full copy of its data under a key the caller
  chose. Who may branch what is an application decision and this demo does not make one.
- **A branch inherits its parent's encryption key.** Fine for rehearsal, wrong for handing a
  branch to a third party.
- **Deleting a row does not reach the history.** A branch cut from an older snapshot resurrects
  it. Erasure that sweeps snapshot history does not exist.
- **The merge is not atomic across disk and bucket.** Being fenced between replacing the parent's
  file and shipping it leaves the cell quarantined — fail-closed, but needing an operator.
- **The measurements DD-05 owes have not been taken here.** Fork latency against database size,
  and the cliff where the file stops fitting in page cache, are named in
  [DD-05](../../docs/design/DD-05-time-travel-and-forks.md) and not yet run. No performance claim
  in this README is a measured one, because there are none.

## The thing this makes possible that Neon cannot

Neon branches a **project**. This branches a **tenant** — because the data was already one file
per tenant, one customer's database is a separable unit. That is not a smaller version of Neon;
it is a different operation. Branch one customer's database to reproduce their bug against their
real data. Rehearse a migration against the specific tenant most likely to break it.

That last one points at the largest open problem in this project: every deploy migrates every
cell, and a lazy per-cell migration failure is a single-tenant outage. Branching makes that risk
measurable before the deploy rather than after. **The rehearsal harness is not built** — DD-05
stages it as `mix ash_cell.rehearse` — and this demo is the primitive it would sit on, not the
thing itself.

## Running it

Branching reads and writes the snapshot history, so unlike the other demos this one **cannot run
without an object store**. A branch is a copy of a snapshot.

```bash
# 1. an object store, from the library checkout
cd ../.. && scripts/minio.sh

# 2. the bucket this demo uses
mc alias set ashcell http://127.0.0.1:9010 ashcell ashcellsecret
mc mb ashcell/ashcell-branch

# 3. exqlite against SQLCipher — a missing EXQLITE_USE_SYSTEM fails *silently*
cd demos/branch
source .envrc
mix deps.compile exqlite --force

# 4.
mix phx.server
```

Then, at <http://localhost:4000>:

1. Provision a database. It ships once immediately, so it has a point to branch from.
2. Run some DDL and inserts against `main`, and snapshot.
3. Cut a branch. Write different rows to it.
4. **Run on both, side by side** — the isolation claim, visible in one screen.
5. Merge. It fast-forwards.
6. Now do it again, but write to `main` before merging. It refuses, and names both digests.

Step 6 is the demo.

## Tests

```bash
mix test
```

`test/branch/service_test.exs` covers the round trip and the refusals against a real bucket.
The library-level behaviour — fork isolation, txid namespaces, the fast-forward rule, and the
measured reason it is a content digest rather than SQLite's change counter — is in
`ash_cell/test/branch_test.exs`.
