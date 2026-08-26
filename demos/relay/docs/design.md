# relay — design

**Status:** built
**Date:** 2026-08-26
**Decisions:** [ADR-04](../../../docs/decisions/ADR-04-transactions-behind-an-opt-in-flag.md),
[ADR-05](../../../docs/decisions/ADR-05-refuse-cross-cell-transactions.md),
[ADR-08](../../../docs/decisions/ADR-08-fence-by-shared-txid.md),
[ADR-10](../../../docs/decisions/ADR-10-fail-closed-on-a-refused-shipment.md),
[ADR-15](../../../docs/decisions/ADR-15-sqlcipher-from-the-system-build.md),
[ADR-19](../../../docs/decisions/ADR-19-the-cell-cut-is-a-choice.md),
[ADR-20](../../../docs/decisions/ADR-20-choose-a-durability-level.md)
**Design doc it rests on:** [DD-13](../../../docs/design/DD-13-durable-streams.md)
**Lands in:** `lib/relay/{cells,schema,streams,generator}.ex`,
`lib/relay_web/live/stream_live.ex`

## What this is

A resumable token stream. A generator process appends tokens to a cell and fans
them out over PubSub; a reader that reconnects asks for everything after the offset
it last saw and is served from the object store, then the cell, then live.

It is [DD-13](../../../docs/design/DD-13-durable-streams.md) with a face on it. The
library holds every durable part; this app holds the transport, the producer, and
the page.

## What this proves

- **An offset survives the writer.** Killed process, closed cell, deleted file —
  three tests in increasing order of how much is taken away, and the third is the
  only one that could not pass with the entries never leaving local disk.
- **A fresh mount and a reconnect are the same code path.** There is no catch-up
  mode. That is the product-level consequence of an offset being a durable name,
  and it is asserted rather than asserted-about: two clients, one cold and one
  resuming, render the same text.
- **Read-then-subscribe with a discard is the only correct ordering**, and the
  window between the two is real. Subscribing first duplicates; subscribing last
  without re-reading drops. `Streams.resume/2` returns the offset it reached so the
  caller can close it.
- **The RPO is a number on the screen.** "only in the cell" is entries appended and
  not yet shipped. It is not a footnote in a README, and killing the generator
  makes it stop at whatever it was.
- **A takeover continues the offset namespace.** A second generator on a stream
  whose entries have been truncated must not reissue offset 1 — the fourth test.

## Why it needs a cell

For the ordering, and for the flush.

Offsets need one writer. Two processes appending to a shared table both read
`MAX(offset)` and both claim it, so a shared-table version needs a sequence or a
conditional append; the cell removes the concurrency instead
([ADR-04](../../../docs/decisions/ADR-04-transactions-behind-an-opt-in-flag.md)).

The flush is the sharper reason: read a batch, PUT an object, truncate what was
PUT. Two of those interleaving means one truncation removes entries the other
segment did not contain, and the reader that resumes into that hole gets a gap.

**Where the cell is cut, and why not the obvious cut.** Per *user* or per *tenant*
is the obvious choice and it is wrong here: a user may have several generations in
flight, and one cell means one writer, so they would serialise behind each other
for no reason. A stream is the unit of ordering and of resume, so it is the unit of
the writer. The cost is that two of one user's streams cannot be read in one
transaction, which nothing here wants.

## Non-goals

- **Not a model.** The generator emits words from a fixed list on a timer.
- **Not Kafka.** No partitions, no consumer groups, no cross-stream ordering, no
  lag metrics.
- **Not exactly-once.** A reader that crashes before recording its offset re-reads.
- **Not a durability claim.** RPO is the flush interval;
  [ADR-20](../../../docs/decisions/ADR-20-choose-a-durability-level.md) is open
  about the file underneath it.
- **Not a comparison.** No benchmark against Redis streams or a hosted queue. The
  trade is per-stream isolation and no coordination against their throughput, and
  saying so beats implying a measurement nobody ran.
- **No authorisation.** Anyone with a generation id can read it. Who may read whom
  is the application's decision everywhere else in this repo and it is here too.

## Data model

Inside the cell, two tables from `AshCell.Stream.migrate/1` and one of the demo's:

- `ash_cell_stream_entries` — `(stream, seq)`, the payload, the timestamp. The
  offset is `seq`.
- `ash_cell_stream_meta` — the flush watermark and the three `pending_*` columns
  that make a crash mid-flush decidable.
- `generation` — `id`, `prompt`, `started_at`, `finished_at`. Metadata *about* the
  stream, so deliberately not an entry *in* it.

Nothing global. A stream is its cell and its id is its key; standing up Postgres to
record a mapping from a name to itself would prove nothing this demo is about.

## Trade-offs

- **The generator flushes, rather than a separate ticker.** A ticker would be a
  second writer of the stream — serialised by the cell, but not prevented by the
  design. Putting the flush in the writer says the true thing.
- **`retain: 0`.** Retaining entries behind the watermark would make resumes local
  and faster. It would also mean the stitch is rarely exercised, and a stitch that
  is only correct at `retain > 0` is not correct.
- **PubSub for live, never the object store.** A PUT is 50–200 ms and a token is
  not.
- **One stream per cell**, though the library allows many. Nothing here needs two,
  and one keeps the demo's claim about the writer unambiguous.

## Measurements this must produce

Not yet run — this is the outstanding work on this demo, and
[DD-13](../../../docs/design/DD-13-durable-streams.md) names the full list. The
demo owes the last two of them:

- **Resume latency by tier**: offset in the live tail, in the cell, in segments,
  and in a cell this node has never held. Median of 5, warm, MinIO on loopback.
  These four must be reported *together*, because the third and fourth are the
  slow ones and reporting the first alone would be the convenient subset.
- **Resume from 0 vs from the tail** at 1 000 / 10 000 entries, to put a number on
  the O(segments) listing cost the README admits to.

## Where it stops

This section and the README must agree; when behaviour changes, both are part of
the change.

- A returned append is not durable; RPO is the flush interval.
- Reads are not fenced. A node that has lost the cell serves a tail that has
  stopped advancing until it notices.
- No back-pressure: a generator faster than the flush grows the file.
- Resume from 0 is O(segments). No manifest.
- No segment expiry — they accumulate forever.
- The `generation` row is written outside the stream's transaction, so a crash
  between the row and the first token leaves a generation with no entries. Benign
  here, and it is a real ordering the demo does not bother to fix.

## Open risks

- **The flush lives in the generator, so a stream whose generator died has an
  unflushed tail that nothing will ship** until someone opens the page and presses
  flush. In a real system that is a sweeper's job, and there isn't one.
- **A fenced generator exits and the cell is quarantined**, which takes any other
  stream in that cell down with it. Only one stream per cell here, so it does not
  bite — which is a reason to be careful about generalising from this demo.
