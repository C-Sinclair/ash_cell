# DD-11 — Collections: CAS, bounded cache, queue, content-addressed tree

**Status:** draft
**Date:** 2026-08-24
**Decisions:** [ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md), [ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md), [ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md)
**Lands in:** `lib/ash_cell/collections/` (new), building on [DD-06](DD-06-append-log-and-compaction.md) and [DD-08](DD-08-durable-execution.md)

## What this is

Four small structures, each a table and a few functions, ported deliberately from
[s3collections](https://github.com/DamianB-BitFlipper/s3collections) so the comparison is concrete:
a versioned compare-and-swap record, a bounded LRU cache, a leased work queue, and a
content-addressed immutable tree with refcount GC. Large values tier to the object store by content
hash, with the SQLite row as the authority.

The reason to build these is not that they are hard. It is that s3collections builds the same four
on a KV-plus-blob substrate and documents what that substrate costs it — approximate eviction,
at-least-once handlers, orphaned bodies after a crash. Each of those is a property of the
substrate, and a cell has a different one. This is the head-to-head.

## What this proves

- **Eviction is exact, not approximate.** Insert-and-evict is one transaction, so a bounded cache
  holds its bound rather than approximately holding it.
- **CAS is a row.** `UPDATE … WHERE version = ?` with the returned row count as the verdict; no
  external transactional KV store in the design at all.
- **The orphan window is closed for the metadata side and named for the blob side.** An object
  uploaded without its row is discoverable because the intent row precedes the upload
  ([DD-08](DD-08-durable-execution.md)), so a sweep can find it. s3collections' equivalent orphan
  is invisible, and that difference is the substrate showing through.
- **GC is a transaction.** Decrement refcounts, collect the zeroes, delete — atomically for the
  metadata, then lazily for the bodies, with the pending-delete set durable so an interrupted GC
  resumes rather than leaking.
- **Four structures compose.** Dequeue a job, decrement a quota
  ([DD-09](DD-09-counters-and-quotas.md)), append to a log
  ([DD-06](DD-06-append-log-and-compaction.md)), and update a tree ref — in one
  `BEGIN IMMEDIATE`. Two s3collections collections cannot be composed atomically; this is the
  clearest single demonstration of what the cell buys.

## Why it needs a cell

Each structure's *invariant* is a read-modify-write:

- CAS: read the version, compare, write.
- LRU: read the size, evict the coldest, insert.
- Queue: read the next unleased item, lease it, return it.
- Tree GC: read the refcounts, find the zeroes, delete.

On a shared store each needs either a transactional KV layer (s3collections' answer: SlateDB) or
optimistic retries. A cell already serialises them. That is the whole argument, and it is the same
argument as [DD-06](DD-06-append-log-and-compaction.md) and [DD-10](DD-10-tenant-local-graph.md) —
which is itself worth noting: the primitive has one theorem and these are its corollaries.

## Non-goals

- **Not a general-purpose cache or queue for the fleet.** Everything is cell-scoped: a per-tenant
  cache, a per-tenant queue. A shared work queue is Oban.
- **Not a redis replacement.** No pub/sub, no expiry daemon, no data types beyond these four.
- **Not competitive on throughput.** These are correct and local, not fast in absolute terms, and
  the measurement should say so.
- **Not a benchmark suite against s3collections.** One or two honest comparisons on the properties
  that differ (exact vs approximate eviction, orphan discoverability), not a performance shootout
  across languages and substrates.
- **Not streaming.** Blob bodies are put and got whole in v1; streaming is a later question.
- **Not four independent libraries.** They share the blob-tiering and intent machinery, and if they
  cannot, that is a signal the abstraction is wrong.

## Data model

Shared: **`ash_cell_blobs`** — `hash` (primary key), `size`, `store_key`, `refcount`,
`inserted_at`, plus **`ash_cell_blob_intents`** for the commit-intent → upload → commit-result
ordering from [DD-08](DD-08-durable-execution.md), and **`ash_cell_blob_pending_deletes`** so GC
resumes.

Per structure:

- **CAS** — `cas_records`: `key` (pk), `version`, `value` or `blob_hash`, `updated_at`.
- **LRU** — `cache_entries`: `key` (pk), `size`, `last_used` (indexed), `value` or `blob_hash`;
  plus a single-row `cache_meta` holding `total_bytes` so the bound is checked without a
  `SUM` (AshSqlite has no aggregates, so this denormalisation is required rather than an
  optimisation).
- **Queue** — `queue_items`: `id`, `state` (`ready | leased | done | failed`), `lease_until`
  (indexed), `attempts`, `payload` or `blob_hash`, `priority`, `inserted_at`. Lease expiry is
  checked at dequeue time, so no sweeper is needed; a [DD-07](DD-07-durable-timers.md) timer is
  optional for prompt re-delivery.
- **Tree** — `tree_nodes`: `hash` (pk), `kind`, `entries` (children hashes), `blob_hash`; and
  `tree_refs`: `name` (pk), `hash`, `updated_at`. Immutable nodes, mutable named refs, refcounts on
  blobs, mark-and-sweep from the refs.

The blob refcount is the one number two structures share, so it is the one place a bug crosses
structures — worth a property test of its own rather than per-structure tests only.

## Trade-offs

- **Value inline vs blob-tiered, and where the threshold is.** Inline keeps everything
  transactional and grows the file; tiering keeps the file small and introduces the non-atomic
  boundary. Chosen: a configurable byte threshold, default small (~64 KB), because the atomic case
  should be the default and the caller should have to opt into the hard one.
- **Lease expiry at dequeue vs by sweeper.** At-dequeue needs no background work and leaves an
  expired lease undetected until someone asks. Chosen: at dequeue, with the timer as an opt-in.
- **Refcount GC vs mark-and-sweep from refs.** Refcounts are incremental and go wrong silently;
  mark-and-sweep is periodic, self-correcting, and O(graph). Chosen: **both** — refcounts for
  prompt reclamation and a sweep as the reconciler, with the sweep's disagreement with the
  refcounts logged rather than silently corrected, since a disagreement is a bug.
- **Building these at all.** They are the lowest-value tier in this set on their own merits. The
  case for them is comparative and pedagogical, and if they are not going to be used by a demo or
  cited in the write-up, they should not be built. That decision belongs before stage 1.

## Measurements this must produce

Warm cell, median of 5:

- **Ops/sec per structure**: CAS update, cache put with eviction, dequeue, tree node insert.
- **Eviction exactness under concurrency**: 64 concurrent puts against a bounded cache, reporting
  the maximum observed `total_bytes` overshoot. The claim is zero; the measurement is what makes
  that a claim rather than an assertion.
- **Blob threshold cost curve**: put latency at values spanning the threshold (16 KB / 64 KB /
  256 KB / 4 MB), inline versus tiered, so the default threshold is chosen from a number. A
  **cliff** is expected at the threshold itself and its size on the test machine should be stated.
- **GC cost** on a tree of 1 000 / 100 000 nodes, and the cost of an *interrupted* GC resuming.
- **Orphan demonstration, not a benchmark**: kill the process between intent and upload, and
  between upload and commit, and show the sweep finds the orphan in both cases. This is the
  head-to-head with s3collections and it is a test, not a number.
- **Composition**: one transaction touching queue, counter, log, and tree, with its latency
  against the sum of the four done separately.

## Staging

1. **Decide whether to build these at all** — is a demo going to use one, or the write-up cite one?
   A no here is a good outcome and cheaper than four half-used structures.
2. **CAS**, inline values only. Checkable: concurrent CAS, one winner.
3. **LRU** with `cache_meta`. Checkable: the exactness measurement above.
4. **Blob tiering** on [DD-08](DD-08-durable-execution.md)'s intent machinery, plus the sweep.
   Checkable: the two orphan cases.
5. **Queue.** Checkable: lease expiry and redelivery; at-least-once demonstrated deliberately, so
   the semantics are shown rather than described.
6. **Tree + refcounts + mark-and-sweep.** Checkable: a GC that reclaims exactly the unreachable
   nodes, and a resumed GC after a kill.
7. **Measurements**, then a `vcs` cross-check — its object store is this tree, and if the two
   disagree about the model, the demo is the one that is right.

## Where it stops

- All four are cell-scoped. Nothing here is fleet-wide.
- **Queue delivery is at-least-once at the effect boundary**, exactly like s3collections. The cell
  makes the *state* transition exactly-once ([DD-08](DD-08-durable-execution.md)); it cannot make
  an outbound call once.
- Blob bodies live in the object store, so a blob-tiered value is not covered by the cell's
  transaction, is not in the encrypted SQLite file, and is not covered by whole-file snapshots
  ([ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md)). A restored cell can
  reference a blob a lifecycle rule deleted. This is the largest gap in this document.
- Blob encryption is the object store's, not SQLCipher's — so the "one encrypted file" story does
  **not** extend to tiered values, and `shroud`'s stronger claim would be broken by using them.
- No streaming, no partial reads, no range gets.
- The tree is content-addressed with one hash function, not negotiable per tree.
- Cache eviction is exact for bytes, not for a count-plus-bytes policy.

## Open risks

- **This is the tier most likely not worth building**, and stage 1 exists to kill it cheaply. Four
  structures nobody uses is worse than a paragraph in the write-up saying they are trivial on a cell.
- **The blob boundary undoes several of the library's stronger claims** (single encrypted file,
  snapshot completeness). Either blob tiering stays off by default and loudly documented, or the
  claims need qualifying everywhere they appear — including CLAUDE.md.
- Refcounts and the sweep disagreeing is a real possibility and the design logs rather than hides
  it; whether logging is enough is unresolved.
- Overlap with `vcs`: if the tree here and `vcs`'s object store diverge, there are two models of
  the same thing in one repo.
