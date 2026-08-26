# ADR-24 — A segment set is not a disjoint cover

**Status:** corrects an earlier belief
**Date:** 2026-08-26
**Deciders:** Conor
**Relates to:** [DD-13](../design/DD-13-durable-streams.md), `lib/ash_cell/stream.ex`,
`test/stream_test.exs`, [`demos/relay/`](../../demos/relay),
[ADR-08](ADR-08-fence-by-shared-txid.md)

## The decision

A stream reader must **de-duplicate by offset** and must not trust the object store's listing to
be duplicate-free. `AshCell.Stream.segment_starts/3` applies `Enum.uniq/1` to the starts it
parses out of a listing, and `from_segments/6` applies `Enum.uniq_by(& &1.offset)` after sorting
the entries it assembled. One offset appears in a read exactly once, whatever the store returned
and whatever segments exist.

## Context

`AshCell.Stream`'s read path stitches three tiers — segments in the object store, unflushed rows
in the cell, live fan-out — and it was written on the belief that the segment set is a *disjoint
cover*: every offset lives in exactly one segment, so the union of the tiers needs concatenation
and nothing else. That belief was load-bearing and it was wrong.

It surfaced as an intermittent failure of the one test the design doc calls load-bearing, `resume
is exact while a flush runs`: roughly one run in eight, a reader resuming mid-stream got a
**duplicate** offset. Not a gap — the flush-before-truncate ordering held throughout — but a
repeated entry, which for a token stream is a repeated word and for an event stream is a repeated
effect.

Instrumenting the stitch showed the duplicate was entirely inside the object-store half, and that
re-listing the segments immediately afterwards showed **no overlapping segments at all**: every
key `k` held a segment starting at `k`, with no two extents intersecting. The store's listing had
returned the same key twice while another segment was being written; the reader fetched that
segment twice and emitted its entries twice.

Chasing the cause turned up a second, independent way for the same symptom to arise, which is
what settled the shape of the fix. Segments genuinely *can* overlap. A displaced writer and its
successor may hold different watermarks, so one writes the segment starting at 10 covering 10–13
while the other writes the segment starting at 12 covering 12–15. Those are different keys, so
neither conditional write is refused, and the start-only key of
[ADR-08](ADR-08-fence-by-shared-txid.md) does not fence that case — it fences two writers
computing the *same* start, which is the common case and not this one.

## Options considered

### Option A — treat a duplicated listing as a store bug and pin the store

Report it upstream, require a version that does not do it. Costs: the reader is still wrong on
the overlap case, which is ours and not the store's; and it makes correctness depend on a
property no S3 implementation actually promises. Lost.

### Option B — make the reader de-duplicate by offset

`uniq` on the parsed starts, `uniq_by(& &1.offset)` on the assembled entries. Costs: one sort and
one pass over the read, and it *hides* a genuine divergence — where two overlapping segments hold
different payloads for one offset, the reader silently picks the lower-keyed one instead of
raising. Won.

### Option C — de-duplicate and raise on a payload conflict

Option B, plus comparing payloads for a repeated offset and failing the read when they differ.
Costs: a read that raises on a condition the caller cannot act on, in the middle of a resume,
where the alternative is a deterministic answer. Deferred rather than rejected — it is the right
thing to do once there is somewhere for the alarm to go.

### Option D — a manifest object listing the segments, written conditionally

Removes the listing from the read path entirely, so a duplicated listing cannot be observed and
the reader knows each segment's extent without fetching it. Costs: another conditional write on
the flush path, another thing to fence, and it does not fix the overlap case either — two writers
with different watermarks would contend on the manifest, which is a *better* failure but a new
mechanism. Wanted for the O(segments) problem regardless; not built, and not the fix for this.

## Decision and why

Option B, because the reader is the only place that sees every source at once, and because the
duplicate had two independent causes with one remedy. The listing duplicate is the store's
behaviour and not something we can forbid; the overlap is ours and the start-only key provably
does not fence it. A reader that assumes disjointness is wrong in both cases, and a reader that
de-duplicates is right in both.

The measurement that settled it: before the change, `resume is exact while a flush runs` failed on
2 of 16 whole-file runs, and on the seed that reproduced it the duplicate was a single offset from
a single segment fetched twice. After the change, **46 consecutive runs with no failure**,
including the seeds that had reproduced it. The two new tests in the
`the segment set is not assumed to be a disjoint cover` block cover both causes directly, so the
guard does not depend on catching the race again.

## Consequences

- **What it rules out.** Using the count of entries a read returns to infer how many segments
  were consulted, or treating a read as a faithful replay of the *store's* contents. It is a
  faithful replay of the *stream*, which is the useful guarantee and not the same one.
- **What it makes worse.** A read now sorts and uniqs, so it is O(n log n) in the entries
  returned rather than O(n). Immaterial next to the object-store round trips, and unmeasured
  because of that — labelled an estimate, not a measurement. More seriously, a genuine payload
  divergence between two overlapping segments is now **silent**: the reader picks the
  lower-keyed segment's version and says nothing.
- **What stays open.** Option C, raising on a payload conflict. And the overlap case itself:
  de-duplication makes the *read* well-defined but does nothing about two writers having written
  disagreeing history. Fencing that would need the watermark to be part of the key, which
  reintroduces exactly what [ADR-08](ADR-08-fence-by-shared-txid.md) removed.
- **What now depends on it.** Every resume in `demos/relay` and every caller of
  `AshCell.Stream.read/5`. A future optimisation that skips the sort — because "segments do not
  overlap" — puts the bug straight back, and the two dedicated tests are what stops it.

## Evidence

- `test/stream_test.exs`, `the segment set is not assumed to be a disjoint cover`:
  `overlapping segments read back contiguously, once each` constructs the displaced-writer
  overlap directly (segment `5` covering 5–12 and segment `9` covering 9–12, both accepted by
  `If-None-Match`), and `a duplicated key in the listing yields one copy of each offset` covers
  the listing case.
- `test/stream_test.exs`, `resume is exact while a flush runs`: the failing observation.
  Instrumented output from the reproducing run, offsets 1–34 requested from 1:
  `cold = [2, …, 18, 19, 19, 20, …, 34]`, `dupes = [19]`, and the segment extents at that instant
  `[{1,1,2,2}, {3,3,6,4}, {7,7,9,3}, {10,10,13,4}, {14,14,14,1}, …, {36,36,36,1}]` — no two
  extents intersect, so offset 19 existed in exactly one segment and was read twice.
- Failure rate before: 2 of 16 whole-file runs. After: 0 of 46, seeds
  `200×53 … 245×53`, MinIO on loopback, the same machine and the same test parameters
  (300 appends, `batch: 7`, `retain: 0`, flusher running for the full duration).
- **Not verified:** which MinIO behaviour produces the duplicated key, and whether AWS S3 does
  the same. The fix does not depend on the answer, which is why it was not chased further — but
  it means the listing case is guarded by a constructed test rather than by a reproduction of
  the store's actual behaviour.

## Notes

The flake was nearly missed. It first appeared as a single failure in a run whose output had
already been truncated to the last few lines, then did not reproduce in six consecutive runs, then
did not reproduce in fourteen runs of that test alone — it needed the whole file, which is what
warms enough segments for the listing to be contended. A one-in-eight failure in the test a design
doc names as load-bearing is worth the loop it takes to catch.

The instrumentation that found it lived inside `stitched/5` and logged `cold`, `local` and the
segment extents whenever the merged offsets were not strictly increasing and unique. That is worth
re-adding temporarily if this area ever misbehaves again; it is much faster than reasoning about
the interleaving, which is what the first several attempts here did without success.
