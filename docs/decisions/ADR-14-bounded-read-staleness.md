# ADR-14 — Bound read staleness on the monotonic clock, and expose it as explicit modes

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [`docs/spec.md`](../spec.md) · [ADR-08](ADR-08-fence-by-shared-txid.md) ·
[ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md)

## The decision

`AshCell.Ownership` refuses to serve once the local lease TTL has passed, measured on the
**monotonic** clock so an NTP step cannot silently widen the staleness window. Staleness is
exposed as three explicit modes rather than one default behaviour: `:none`, `:bounded`
(default), `:strict`.

## Context

Fencing protects writes, not reads. A partitioned node keeps serving stale reads from a cell it
has lost — writes are refused by the shared-txid fence
([ADR-08](ADR-08-fence-by-shared-txid.md)), but nothing stops a stale node from answering a read
request against data it no longer legitimately owns. This was raised by adversarial review, not
found by a test failure.

## Options considered

### Option A — `:none`

No clock assumption at all. Correct under arbitrary clock behaviour, but gives no bound on how
stale a read can be, and cannot help against a partitioned node continuing to answer reads.

### Option B — `:bounded` (chosen as default)

Refuse to serve once the local lease TTL has passed, measured on the monotonic clock. Bounds
staleness to the TTL window, but the bound is a duration, and durations depend on the clock
being trustworthy over that window.

### Option C — `:strict`

Re-read the lease per read. No staleness window at all, but it discards the performance
argument entirely, so it is for specific reads and never as a global default.

## Decision and why

`:bounded` is the default because it is the only option that gives a usable guarantee without
paying the round trip of `:strict` on every read. Measuring against the monotonic clock rather
than wall clock is what makes the bound trustworthy: an NTP step on wall clock could otherwise
silently widen the window a stale node believes it is still inside.

This is the only place in the design where clock skew matters at all: "everything else is safe
under arbitrary drift because correctness rests on conditional writes. Bounded staleness cannot
be — the bound *is* a duration." Every other guarantee in the system (fencing, generation
counters, lease claims) is built on conditional writes against an object store and holds
regardless of clock behaviour. This one cannot be, because a duration has no meaning without a
clock.

## Consequences

- **What it rules out.** A read guarantee as strong as the write fence, without paying
  `:strict`'s round trip on every read.
- **What it makes worse.** The system now has exactly one place where clock trustworthiness is
  load-bearing, where previously there was none.
- **What stays open.** This is a named, accepted trade-off, not a solved problem. Reads still
  are not fenced the way writes are — a partitioned node inside its TTL window can still serve
  stale reads legitimately, by construction of `:bounded`.
- **What now depends on it.** Any caller wanting a stronger guarantee than the default must opt
  into `:strict` explicitly and pay for it per read; there is no global escape from `:bounded`'s
  trade-off.

## Evidence

- `AshCell.Ownership` measures against the monotonic clock, not wall clock.
- The three modes — `:none`, `:bounded` (default), `:strict` — are as described above.
- Not verified: no measurement of `:strict`'s round-trip cost is recorded; no test of behaviour
  under an actual clock step is recorded here.

## Notes

Fencing protects writes, not reads, remains on the open-problems list even after this ADR —
this bounds the read-staleness problem, it does not close it.
