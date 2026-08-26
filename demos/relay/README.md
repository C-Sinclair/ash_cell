# relay — one cell per stream

A stream of tokens you can walk away from and come back to. Close the tab at token
4 132, reopen it, and get token 4 133 — after the process generating them has been
killed, after the cell has been closed, and after its file has been deleted off
local disk.

The cell cut is **one cell per stream**. A stream is the unit of ordering and the
unit of resume, so it is the unit of the single writer. See
[ADR-19](../../docs/decisions/ADR-19-the-cell-cut-is-a-choice.md) and this demo's
[design doc](docs/design.md).

## What it proves

- **An offset is a durable name, not a session-local counter.** A reader holding
  offset N gets exactly the suffix after N, whichever tier it is in.
- **The stitch across three tiers has no gap and no duplicate.** Segments in the
  object store, unflushed entries in the cell, and live tokens over PubSub, walked
  in that order. Read first, subscribe second, discard what the read covered —
  the other orderings give you a duplicate and a gap respectively.
- **Ordering costs no coordination.** Kafka needs a partition leader and a
  consensus protocol for what one cell's single writer already gives. There is no
  lease here beyond the cell's own, no quorum, and no new failure detector.
- **The RPO is visible rather than described.** The UI shows how many entries are
  in the cell and not yet in the bucket. Kill the generator and that number is
  what a node loss would cost you.

## Where it stops

This is the part to read before quoting any of the above.

- **A returned append is not durable.** It is in the cell file, and reaches the
  object store at the next flush — every 40 tokens here. RPO is the flush
  interval, not zero, and [ADR-20](../../docs/decisions/ADR-20-choose-a-durability-level.md)
  is open about the file itself.
- **Reads are not fenced.** A node that has lost the cell keeps serving its
  stream's tail until it notices. A resuming reader that lands on it sees an
  offset that has stopped advancing.
- **No back-pressure.** A generator faster than the flush grows the cell file and
  nothing stops it.
- **Resuming from offset 0 lists every segment**, so it is O(segments). A manifest
  object would fix it and is not built. You can see this: a long generation's
  "replay from 0" gets slower as it runs.
- **One stream per cell here**, though the library allows many. Two streams in one
  cell share a writer, which is a choice this demo does not need to make.
- **Not Kafka.** No partitions, no consumer groups, no cross-stream ordering. One
  stream, one writer, N readers each holding their own offset.
- **The generator is not a model.** It emits words from a fixed list on a timer.
  Nothing here is a claim about inference.

## Running it

Needs MinIO. Unlike most of the demos this one is close to pointless without it:
with no bucket there are no segments, so a resume can only ever be served from the
cell, which is the half that was already easy.

```bash
../../scripts/minio.sh                  # from ash_cell/
source .envrc                           # SQLCipher, and it is not optional
mix deps.compile exqlite --force
mix phx.server
```

Then open <http://localhost:4040>, hit **generate**, and:

1. Watch the tiers. "only in the cell" is the RPO in entries; it drops to zero
   every time the generator flushes.
2. **kill the generator** mid-stream. The process dies without flushing.
3. **reconnect at N** — the client throws away every token it holds and asks for
   what comes after its offset. Same text.
4. **close the cell**, then reconnect again. Now the resume has to reopen it.
5. **flush now**, then delete the cell's file from `priv/cells/` and reconnect.
   The bucket is all there is, and it is enough.

A missing `EXQLITE_USE_SYSTEM` at dep-compile time fails **silently** and gives
you plain SQLite with no encryption. `mix cipher.check` in `ash_cell` is the
guard; see [ADR-15](../../docs/decisions/ADR-15-sqlcipher-from-the-system-build.md).

## The tests

```bash
mix test
```

Four of them are the demo's actual claims, in increasing order of how much has
been taken away: the generator killed, the cell closed, the cell's file deleted,
and a second generator taking over a stream whose entries have been truncated —
that last one guards offsets restarting at 1, which is a bug that was written and
caught rather than imagined.

They need MinIO too, and they use wall-clock time in cell names, because the
bucket outlives the VM and `System.unique_integer/1` does not.

## Where the code is

Almost nothing durable is in this app. `AshCell.Stream` does the appending, the
flushing, the fencing and the stitch; what is here is the part a product needs and
the library does not have.

| File | What it is |
|---|---|
| [`lib/relay/streams.ex`](lib/relay/streams.ex) | The whole API. Read-then-subscribe lives here. |
| [`lib/relay/generator.ex`](lib/relay/generator.ex) | One process per stream, and the only writer of it. It flushes, because the flush is the writer's job. |
| [`lib/relay/cells.ex`](lib/relay/cells.ex) | Where the cell is cut, and the bucket. |
| [`lib/relay/schema.ex`](lib/relay/schema.ex) | Two library tables and one of the demo's own. |
| [`lib/relay_web/live/stream_live.ex`](lib/relay_web/live/stream_live.ex) | The page. Note what is *not* in it: no `AshCell.LiveView`, no held binding. |
