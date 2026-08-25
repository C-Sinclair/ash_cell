# branch — design

**Status:** built
**Date:** 2026-08-25
**Decisions:** [ADR-07](../../../docs/decisions/ADR-07-opaque-cell-keys.md),
[ADR-08](../../../docs/decisions/ADR-08-fence-by-shared-txid.md),
[ADR-06](../../../docs/decisions/ADR-06-own-repo-for-shared-tables.md),
[ADR-12](../../../docs/decisions/ADR-12-whole-file-snapshots-on-a-schedule.md),
[ADR-23](../../../docs/decisions/ADR-23-merge-by-fast-forward-or-refuse.md)
**Design doc it rests on:** [DD-05](../../../docs/design/DD-05-time-travel-and-forks.md)
**Lands in:** `lib/branch/{cells,catalog,service,schema}.ex`, `lib/branch_web/live/console_live.ex`,
and in the library at `lib/ash_cell/{history,branch}.ex`

## What this is

A branching database service: provision a SQLite database, run SQL against it, snapshot it, cut a
named branch from any snapshot, write to branch and parent independently, then promote the branch
or be refused. The cell cut is **one cell per branch**, keyed `db:<database>@<branch>`.

It is [DD-05](../../../docs/design/DD-05-time-travel-and-forks.md) stages 1 and 3 made visible,
plus the merge rule DD-05 had deferred and
[ADR-23](../../../docs/decisions/ADR-23-merge-by-fast-forward-or-refuse.md) now settles.

## What this proves

- A branch is genuinely isolated in both directions — two files, two connections, not a filtered
  view of one table.
- A branch is cut from an addressable *point*: snapshots are immutable and keyed by txid, and an
  inexact txid resolves down and says so.
- A branch inherits none of its parent's fencing state. It is a different cell key, so it takes
  its own lease and its own txid namespace, and ADR-08 works unchanged on a construct it was not
  designed for.
- Promotion is fast-forward or refusal, and the refusal names both content digests.
- The promoted state is durable before promotion reports success — deleting the parent's local
  file and restoring from the bucket returns the merged database.
- Provenance kept outside both cells is load-bearing, not tidiness: a record written inside the
  parent is copied into the branch, which then claims to be its own parent.

## Why it needs a cell

Branching a tenant's database in a shared-schema Postgres means either copying rows out under a
new tenant id — which is not isolation, it is duplication inside the same blast radius — or
restoring an entire cluster to read one customer's past. Because a cell is one file, "this
database at txid N" is an object in a bucket and a branch is a copy of it.

The sharper claim is the one Neon cannot make: Neon branches a *project*. This branches a
*tenant*, because per-tenant physical partitioning already made one customer's database a
separable unit.

## Non-goals

- **Not constant-time branching.** No page server, no LSN-addressed copy-on-write. Branching is a
  whole-file copy, O(size), with no deduplication.
- **Not a merge of diverged branches.** Refused, permanently, per ADR-23.
- **Not continuous time travel.** Branch points are snapshot boundaries.
- **Not authorisation.** Who may branch what is the application's.
- **Not the migration-rehearsal harness.** That is DD-05 stage 5 (`mix ash_cell.rehearse`) and is
  the thing this demo is a primitive *for*, not the thing itself.

## Data model

Inside a cell: whatever the user's SQL creates. The migrator installs only a `_branch_meta` marker
table so `PRAGMA user_version` has a baseline. This is the one demo whose schema is *data*, which
is what makes a branch able to carry a schema change.

Outside, in `Branch.CatalogRepo` — its own repo module, because Ecto's dynamic binding is per repo
module and a shared table on `Branch.CellRepo` would inherit whichever cell the caller had bound
([ADR-06](../../../docs/decisions/ADR-06-own-repo-for-shared-tables.md)):

- `databases(name, created_at)`
- `branches(id, database, name, parent, from_txid, digest, status, created_at, merged_at)`

`digest` is the number promotion depends on. Losing the catalog makes open branches unmergeable;
it does not make them unreadable.

## Trade-offs

- **Snapshot cadence of 5 s.** Chosen so the history is visible in a demo session. It is not a
  production cadence and the README says so.
- **A SQL console rather than Ash resources.** The subject is the database file, and a console is
  the shortest path to letting somebody see for themselves that the parent did not change. It
  costs the demo any statement about the resource layer.
- **Ship-if-dirty before branching.** Cutting from whatever the periodic policy last shipped would
  silently drop the writes a user made seconds earlier. Costs a shipment on every branch; skipped
  when the digest already matches the newest snapshot.
- **Lease claimed lazily on first touch, not at provision.** Simpler, and it makes the refusal path
  real code rather than an assumption.

## Measurements this must produce

**None have been taken, and no number in the README is a measurement.** What is owed, inherited
from DD-05 and still outstanding:

- Fork latency against database size at 1 MB / 10 MB / 100 MB / 1 GB, with the cliff where the
  file stops fitting in page cache stated, not just the good number.
- Merge latency, split into digest / copy / ship, since it is two full-file passes.
- Storage amplification at 1 branch per database, and at 10.
- Parent interference: p99 write latency on a parent while branches of it are materialising.

## Where it stops

See the README's *Where it stops*, which is the version a reader arrives at first and is part of
any change to this demo's behaviour. In short: no diverged merge, no O(1) branching, no
deduplication, branch points are snapshot boundaries, no authorisation, a branch inherits the
parent's encryption key, erasure does not reach history, and merge is not atomic across disk and
bucket.

## Open risks

- **Storage cost is unbounded by design.** Whole-file snapshots multiplied by branches. Bucket
  lifecycle policy is the operator's and is not configured here.
- **`ObjectStore.list/2` has no S3 pagination**, so a database with more than 1000 snapshots lists
  wrong — and this demo ships every 5 s. Already on the ADR index's open list; branching makes it
  reachable in an afternoon of leaving the demo running.
- **The catalog is a single point of failure for promotion**, and nothing backs it up.
- **A branch of a cell this node does not own, or one mid-drain, should refuse**; neither refusal
  is designed yet (DD-05 names this too).
