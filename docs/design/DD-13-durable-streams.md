# DD-13 — Durable streams

**Status:** building
**Date:** 2026-08-26
**Decisions:** [ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md), [ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md), [ADR-07](../decisions/ADR-07-opaque-cell-keys.md), [ADR-08](../decisions/ADR-08-fence-by-shared-txid.md), [ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md), [ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md), [ADR-20](../decisions/ADR-20-choose-a-durability-level.md), [ADR-24](../decisions/ADR-24-a-segment-set-is-not-a-disjoint-cover.md)
**Lands in:** `lib/ash_cell/stream.ex`, `test/stream_test.exs`, and [`demos/relay/`](../../demos/relay)

## What this is

An append-only stream inside a cell whose **offsets survive the writer**. Entries are appended
to two tables in the cell file; a flush batches unflushed entries into an immutable,
offset-keyed object in the store and truncates them locally; a reader resuming at any offset is
served from segments, then from the cell, then from live fan-out, with no gap and no repeat.

It is the resumable-response problem — the tab closes at token 4 132 and reconnects wanting
token 4 133, on a different node, after the process that was generating them has died.

## What this proves

- **An offset is a durable name, not a session-local counter.** A reader holding offset N
  gets exactly the suffix after N, whether N is in the object store, in the cell file, or
  still being appended — and gets it after the writing process, and then the node, has gone.
- **The stitch across three tiers has no gap and no duplicate.** Two separate arguments, and
  originally only the first was made. *No gap*: flush strictly precedes truncation, so any offset
  removed from the cell is already in a segment. *No duplicate*: the reader de-duplicates by
  offset, because a segment set is **not** a disjoint cover — see
  [ADR-24](../decisions/ADR-24-a-segment-set-is-not-a-disjoint-cover.md), which exists because
  the concatenation-only version shipped and failed one run in eight.
- **Segment keys fence exactly as txids do.** One offset namespace per stream, shared by every
  owner past and present ([ADR-08](../decisions/ADR-08-fence-by-shared-txid.md)), so a
  displaced writer's flush collides with its successor's *before* the append is acknowledged
  as durable. Keying a segment by `start`-only rather than by `start-end` is what makes both
  owners compute the same key; the `start-end` variant is the generation bug again, and is
  tested as such.
- **A crash between the PUT and the local commit is recoverable, not a stall.** The intent is
  written to the cell before the PUT, so the next flush can tell "my write landed" from "I was
  fenced" by digest rather than by guessing.
- **Ordering costs no coordination.** Kafka needs a partition leader and a consensus protocol
  for what one cell's single writer already gives; the stream adds no lease, no quorum, and no
  new failure detector.

## Why it needs a cell

Two writers appending to a shared table can both read `MAX(offset)` and both claim it, so
offsets need either a sequence (which does not survive a partition being wrong about who is
writing) or a conditional append the store has to implement. The cell removes the concurrency
instead: one writer, `BEGIN IMMEDIATE`, and the offset is `MAX + 1` with the read free
([ADR-04](../decisions/ADR-04-transactions-behind-an-opt-in-flag.md)).

The flush is the sharper reason. It is a read-modify-write — read a batch, put an object,
truncate what was put — and it must not interleave with another flush of the same stream, or
one truncation removes entries the other segment did not contain. This is
[DD-06](DD-06-append-log-and-compaction.md)'s argument with the object store on the far side
of it.

**Where the cell is cut:** per **stream**. A stream is the unit of ordering and the unit of
resume, so it is the unit of the single writer. Cutting per tenant instead would serialise
every one of a tenant's concurrent streams behind one writer, which for the generating
workload this is built for is exactly wrong.

## Non-goals

- **Not Kafka.** No partitions, no consumer groups, no rebalancing, no cross-stream ordering,
  no lag metrics. One stream, one writer, N independent readers holding their own offsets.
- **Not exactly-once delivery.** A reader that crashes after consuming and before recording
  its offset re-reads. Effects on top of that are [DD-08](DD-08-durable-execution.md).
- **Not RPO=0.** See *Where it stops*. This is [ADR-20](../decisions/ADR-20-choose-a-durability-level.md)
  at a higher write rate, which makes it worse rather than better.
- **Not a byte stream.** The offset is an entry index. A reader cannot resume mid-entry.
- **Not cross-cell fan-in.** Many producers into one stream means one cell, and that is the
  refusal in [ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md), not a gap.
- **Not the live transport.** Live fan-out is `Phoenix.PubSub`; the object store is never in
  the live path and never in the append path.
- **Not a replacement for [DD-06](DD-06-append-log-and-compaction.md).** DD-06 folds a log into
  a snapshot *row*; this ships a log suffix to an *object*. When `AshCell.Log` lands, the entry
  table here is what it should absorb — the flush, the segment namespace, and the stitch are
  what stay.

## Data model

Two tables in the cell, created by `AshCell.Stream.migrate/1` from the application's migrator
(the library does not own the fleet's migration list):

- **`ash_cell_stream_entries`** — `stream` (text), `seq` (integer), `payload` (blob),
  `at` (integer, unix ms). Primary key `(stream, seq)`, which is also the only read path: a
  stream is read by range. `seq` is the offset; the column is not called `offset` because that
  is a SQLite keyword and quoting it everywhere is a worse trade than one name mismatch.
- **`ash_cell_stream_meta`** — `stream` (text, PK), `flushed_through` (integer),
  `pending_start`, `pending_end`, `pending_digest`. The three `pending_*` columns are the
  intent record that makes a crash mid-flush decidable.

In the object store, one namespace per stream, under the cell's own prefix so a cell key change
carries its streams with it ([ADR-07](../decisions/ADR-07-opaque-cell-keys.md)):

    cells/<enc(cell_key)>/streams/<enc(stream)>/segments/<pad(start)>.seg

The key is the **start offset alone**. The end lives in the segment header, so a segment's
extent is discoverable without the key encoding it — which is what lets two owners batching
differently still collide.

## Trade-offs

- **Entry offsets vs byte offsets.** Byte offsets let a client resume mid-entry and make the
  segment index a byte range. Chosen: entry offsets, because resume-mid-token is not a
  requirement and byte offsets make the append transaction carry a running total.
- **Segment keyed by `start` vs `start-end`.** `start-end` reads better and fences nothing,
  for exactly ADR-08's reason. Chosen: `start`.
- **Fence on a colliding segment vs reconcile.** Reconciling (fetch, compare, continue) would
  survive a benign collision; it also cannot distinguish a benign one from a fenced one without
  the digest. Chosen: fence via `AshCell.Manager.fence/1` unless the digest proves the write
  was *ours* ([ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md)).
- **Truncate on flush vs retain a window.** Retaining keeps a resume local and costs file size.
  Chosen: configurable `:retain`, default 0, because correctness must not depend on it — the
  stitch has to be right at retain 0 or it is not right.
- **Flush inline on append vs on a cadence.** Inline is RPO≈0 and pays an object-store round
  trip per token, which is absurd at this write rate. Chosen: cadence, and say the RPO.

## Measurements this must produce

Warm cell, `pool_size: 1` ([ADR-13](../decisions/ADR-13-pool-size-one-and-cache.md)), MinIO on
loopback, median of 5:

- **Append throughput** at payload 64 B / 1 KB / 16 KB, appends/sec, single writer.
- **Flush cost vs batch size** at 100 / 1 000 / 10 000 entries: wall time and bytes PUT.
- **Resume latency by tier** — offset in the live tail, offset in the cell, offset only in
  segments, and offset in a cell this node has never held (restore included). These four are
  the demo's headline and must be reported together, because the third and fourth are the ones
  that are slow.
- **The stitch under concurrent flush**: 1 000 iterations of a reader resuming at a random
  offset while a flush runs, asserting the read equals the append order exactly.
- **p99 append latency during a flush** — a *cliff*: state the batch size at which it crosses
  50 ms.

## Staging

1. **Tables, `append/4`, `read/5` against the cell only.** Checkable: offsets are dense and
   monotonic; a read from any offset returns the exact suffix.
2. **`flush/4` and the segment format.** Checkable: entries truncated locally are still read
   back byte-identically through segments; `retain: 0`.
3. **The stitch property test.** Concurrent flush and resume, with the flusher running for the
   whole appender's duration rather than a fixed number of times — a fixed count finishes early
   and leaves the contended half of the run untested, which is how
   [ADR-24](../decisions/ADR-24-a-segment-set-is-not-a-disjoint-cover.md)'s bug survived its
   first version.
4. **Fencing.** Two owners, one displaced; assert the collision, and assert the `start-end`
   key variant would *not* have collided — both halves, as `test/fencing_test.exs` does.
5. **Crash between PUT and commit.** Both branches: our write landed, and we were fenced.
6. **[`demos/relay/`](../../demos/relay)** — the thin Phoenix app, and the measurements above.

## Where it stops

- **A returned `append` is not durable.** It is in the cell file, subject to
  [ADR-20](../decisions/ADR-20-choose-a-durability-level.md); it reaches the object store at
  the next flush. RPO is the flush interval, and this must not be described otherwise.
- **Reads are not fenced.** A node that has lost the cell keeps serving its stream's tail until
  it notices — the same hole `AshCell.Lease` names, and a resuming reader that lands on it sees
  an offset that has stopped advancing.
- **No back-pressure.** An appender faster than the flush grows the cell file, and nothing
  stops it.
- **Segment listing is O(segments).** Resuming from offset 0 on a long-lived stream lists every
  segment. A manifest object would fix it and is not built.
- **No compaction or expiry of segments.** They accumulate forever.
- **One writer per stream is assumed, not enforced above the cell.** The cell enforces it for
  anything going through the cell; a second process appending to the same cell from the same
  node is serialised, not refused.

## Open risks

- **A payload divergence between two overlapping segments is silent.** De-duplication makes the
  read well-defined; it does nothing about two writers having written disagreeing history for one
  offset, and the reader picks the lower-keyed segment without saying so
  ([ADR-24](../decisions/ADR-24-a-segment-set-is-not-a-disjoint-cover.md), option C).
- **The stitch is only correct while flush strictly precedes truncate**, and that ordering
  lives in one function. If a future optimisation truncates optimistically, the property test
  in stage 3 is the only thing that catches it. It must not be marked slow and skipped.
- **`MAX(seq) + 1` under the bulk-write path** is DD-06's open question and is inherited here.
- **A fenced stream writer fences the whole cell.** That is
  [ADR-10](../decisions/ADR-10-fail-closed-on-a-refused-shipment.md) applied consistently, and
  it means one misbehaving stream takes the cell's other streams down with it. Whether that is
  right is unresolved.
