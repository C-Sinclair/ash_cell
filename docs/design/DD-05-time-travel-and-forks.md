# DD-05 — Time travel and copy-on-write forks

**Status:** draft
**Date:** 2026-08-24
**Decisions:** [ADR-07](../decisions/ADR-07-opaque-cell-keys.md), [ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md), [ADR-14](../decisions/ADR-14-bounded-read-staleness.md), [ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md), [ADR-08](../decisions/ADR-08-fence-by-shared-txid.md)
**Lands in:** `lib/ash_cell/history.ex` (new), `lib/ash_cell/replicator.ex`, `lib/ash_cell/manager.ex`, `lib/ash_cell/cell.ex`

## What this is

Two read/write operations over the snapshot history that already exists in the object store.
`AshCell.at(cell_key, txid)` opens a **read-only** cell from an immutable snapshot, so a caller
can query a tenant's database as it stood at a past commit. `AshCell.fork(cell_key, from: txid)`
materialises that snapshot under a *new* cell key, giving a writable, fully isolated copy that
diverges from the original.

Both are thin: `Replicator.restore/3` already takes a txid and `snapshot_key/2` already keys
snapshots by one. What is missing is a read-only open path, a fork-provenance record, and the
refusal rules.

## What this proves

- A tenant's database can be read at an arbitrary past txid without disturbing the live cell,
  and two such reads at the same txid return byte-identical results.
- A fork is genuinely isolated: writes to the fork are invisible to the origin and vice versa,
  because they are two files with two connections and two leases.
- A schema migration can be rehearsed against a real tenant's data before the fleet-wide deploy,
  and a failed rehearsal costs the fork and nothing else.
- Fork creation cost is a function of snapshot size, not of tenant history length — the copy is
  a whole-file restore, not a log replay ([ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md)).
- A read-only cell cannot be written to even by a caller that holds a binding: the refusal is at
  the connection, not a convention.

## Why it needs a cell

This is the clearest case in the library. Time travel over a shared multi-tenant table means
either temporal columns on every row, or restoring an entire cluster to read one customer's past.
Because a cell is *one file*, "the tenant's database at txid N" is an object in a bucket, and
copy-on-write is a file copy rather than a distributed-snapshot problem. Fork isolation is the
same argument: a forked tenant is a new cell key, and [ADR-07](../decisions/ADR-07-opaque-cell-keys.md)
already says the key is opaque, so `"acme"` forking to `"acme@fork:rehearsal-31"` needs no new
routing concept — only an injective encoding, which `CellKey.encode/1` is.

## Non-goals

- **Not continuous time travel.** Reads land on snapshot boundaries, which are periodic
  ([ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md)). Asking for a txid
  between two snapshots resolves *down* to the newest snapshot at or before it, and says so in
  the return value. Arbitrary-instant recovery would need per-commit WAL shipping; that is
  Path B and stays deferred.
- **Not a general merge.** Merging two *diverged* histories is out, and stays out: it has no
  correct answer without a domain rule ([ADR-23](../decisions/ADR-23-merge-by-fast-forward-or-refuse.md)).
  What does exist is the decidable case — a fork whose origin has not been written to since the
  branch point fast-forwards, and anything else is refused with both content digests. The
  log-shaped fold in [DD-06](DD-06-append-log-and-compaction.md) is still the only path that
  merges divergence, and it is still deferred.
- **Not a branch of the fleet.** One cell forks. Forking a consistent set of cells is a
  distributed snapshot and is refused, for the same reason a transaction cannot span two cells
  ([ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md)).
- **Not a backup product.** Retention, lifecycle rules, and cost management of the snapshot
  history are the operator's, via bucket policy.
- **Not writable history.** A snapshot is never mutated; a fork is a new object prefix.

## Threat model

| Adversary | What they get | What stops them |
|---|---|---|
| Caller who forks a cell they may not read | A full copy of a tenant's database under a key they *can* read | Nothing in this layer. Fork is a privileged operation and authorisation is the application's; the doc must say so rather than imply the cell checks. |
| Caller who guesses a fork key | Access to the fork's data | `CellKey.encode/1` is injective but not unguessable. Fork keys must carry application-supplied entropy if the fork is not meant to be enumerable. |
| Operator restoring an old snapshot over a live cell | Silent rollback, and a txid range reused | `fork` never targets an existing key; `restore` into a live key requires the cell closed and the lease held. A refused shipment fails closed ([ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md)). |
| Deleted-data resurrection (a GDPR erasure undone by a fork of an older snapshot) | The erased rows | Nothing automatic. Erasure must sweep the snapshot history, and this doc does not implement that. Named in *Where it stops*. |
| A fork inheriting the origin's SQLCipher key | Plaintext access under a second key | Intended for rehearsal forks, wrong for handing a fork to a third party. Re-keying a fork is out of scope here. |

## Data model

Nothing new inside a cell. Two things outside it:

- **The fork record**, in the shared (non-tenanted) store on its own repo module
  ([ADR-06](../decisions/ADR-06-own-repo-for-shared-tables.md)): `origin_cell_key`,
  `fork_cell_key`, `from_txid`, `resolved_txid`, `created_at`, `purpose`. Provenance has to
  outlive the fork, and it must not live *in* either cell, because a fork that inherits its own
  provenance row is a fork that lies about where it came from.
- **The snapshot listing**, which already exists as the object-store prefix
  (`Replicator.snapshot_prefix/1`). `AshCell.History.list/1` exposes it as
  `[{txid, size, shipped_at}]` — the read side of `latest_txid/2`.

A read-only cell is an ordinary `AshCell.Cell` with three differences: its file lives under a
scratch path, it takes **no lease and claims no txid** (it owns nothing, so there is nothing to
fence), and its repo opens with `mode: :readonly` so a stray write raises from SQLite rather
than from a wrapper.

## Trade-offs

- **Resolve-down vs refuse on an inexact txid.** Refusing is more honest; resolving down is
  usable. Chosen: resolve down, and return the txid actually opened so the caller can see the
  gap. A caller that needs exactness compares the two.
- **Fork by whole-file copy vs by lazy page fetch.** Lazy pages would make fork O(1) and reads
  slow and networked; whole-file makes fork O(size) and reads local. Cells are small by design,
  so whole-file wins, and the cost is a measurement this doc owes.
- **Read-only cell as a real cell vs an ad-hoc Ecto connection.** A real cell inherits eviction,
  quarantine, and the binder for free ([DD-01](DD-01-cell-runtime.md)), at the cost of teaching
  the runtime about a cell that has no lease. Chosen: a real cell, because the alternative
  duplicates the binding path and [ADR-02](../decisions/ADR-02-bind-in-the-data-layer.md) exists
  precisely so there is one.
- **Fork keys derived vs supplied.** Derived keys (`origin@fork:n`) are legible and enumerable;
  supplied keys are opaque and the caller's problem. Chosen: caller supplies, library validates
  it is unused, because the threat-model row above makes enumerability a real cost.

## Measurements this must produce

Cold unless stated, median of 5, against MinIO on the loopback (`scripts/minio.sh`):

- **Fork latency vs snapshot size** at 1 MB / 10 MB / 100 MB / 1 GB. A **cliff** is expected
  where the file stops fitting in page cache; state the size at which it appears on the test
  machine, not just the good number.
- **`at/2` open latency**, cold and warm, at the same sizes — and the same measurement for a
  *second* open of the same txid, which should hit the already-materialised scratch file.
- **Read-throughput parity**: the DD-04 manifest-resolve query against a live cell vs against a
  fork of it, to establish a fork is not a degraded copy.
- **Storage amplification** for a fleet at 1 fork per 10 cells: bytes in the bucket before and
  after, because whole-file forks are the expensive choice and the number should be visible.
- **Origin interference**: p99 write latency on a live cell while 8 forks of it are being
  materialised concurrently. The claim is "does not disturb the live cell"; this is what checks
  it.

## Staging

1. **`AshCell.History.list/1` and `resolve/2`.** Read-only, no new state. Checkable: a test
   that ships three snapshots and asserts the listing, and that a txid between two resolves down.
2. **Read-only open — `AshCell.at/2`.** Materialise to scratch, open `mode: :readonly`, no lease,
   no txid claim. Checkable: a query returns the past state; a write raises; the live cell's
   lease and txid are untouched.
3. **`AshCell.fork/2`.** New key, provenance row, writable cell with its own lease. Checkable:
   bidirectional isolation, and a fork of a fork.
4. **Scratch lifecycle.** Eviction of read-only cells, and `AshCell.drop_fork/1` deleting file,
   prefix, and provenance. Checkable: a fork dropped mid-read does not corrupt the reader
   ([ADR-21](../decisions/ADR-21-close-does-not-await-the-connection.md) applies).
5. **Migration rehearsal.** `mix ash_cell.rehearse --tenant acme` forks, migrates, reports, drops.
   Checkable: a deliberately broken migration fails the rehearsal and leaves the origin untouched.
6. **Measurements**, as named above, plus the `rollout` demo forking a channel to preview a
   release.

## Where it stops

- Reads land on snapshot boundaries, so "what did this look like at 14:32" is answered to within
  a snapshot interval, not to the second.
- Merge is fast-forward only, so a branch left open while its origin keeps serving becomes
  unmergeable and has to be re-cut ([ADR-23](../decisions/ADR-23-merge-by-fast-forward-or-refuse.md)).
  Long-lived branches are not a supported shape. There is no diff beyond what the application
  writes itself.
- Merge is not atomic across local disk and the object store: being fenced between the file
  replacement and the shipment leaves the cell quarantined, which is fail-closed but needs an
  operator to recover.
- **Erasure does not reach the history.** Deleting a row in a live cell leaves it in every
  snapshot that preceded the delete, and a fork of one of those snapshots resurrects it. Closing
  this needs a history-sweep operation that does not exist.
- A fork inherits the origin's encryption key. Handing a fork to someone who may not hold that
  key is not supported.
- Nothing here authorises anything. Who may fork whom is the application's.
- Cross-cell consistency: none. Two forks taken "at the same time" are not a consistent cut.

## Open risks

- **Storage cost is unbounded by design.** Whole-file snapshots plus forks multiply quickly.
  Closing it means either bucket lifecycle policy (operator's, and should be documented) or
  incremental snapshots, which is a change to [ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md).
- **A read-only cell has no lease, which is a new shape in the runtime.** Every place that
  assumes a running cell has a lease is a latent bug. Closing it means auditing `Manager`'s
  lease map and `Drain` for that assumption before stage 2 ships.
- **`at/2` on a cell whose newest snapshot is up to a snapshot-interval stale** interacts with
  [ADR-14](../decisions/ADR-14-bounded-read-staleness.md): the staleness bound for a historical
  read is a different bound from a live one, and the API should not let them be confused.
- Fork of a cell mid-drain, or fork of a cell this node does not own. Both should refuse; neither
  refusal is designed yet.
