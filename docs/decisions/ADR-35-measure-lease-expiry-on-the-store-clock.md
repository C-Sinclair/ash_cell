# ADR-35 — Measure lease expiry on the object store's clock

**Status:** corrects an earlier belief
**Date:** 2026-11-01
**Deciders:** Conor Sinclair
**Relates to:** `AshCell.Lease`, `AshCell.ObjectStore`, `AshCell.LeaseRenewer`, [ADR-08](ADR-08-fence-by-shared-txid.md), [ADR-14](ADR-14-bounded-read-staleness.md), [ADR-32](ADR-32-release-a-lease-by-conditional-write.md), [ADR-33](ADR-33-renew-leases-from-one-process-per-fleet.md), [`docs/spec.md`](../spec.md) §8

## The decision

A lease stores `ttl_ms`, not an expiry time. `AshCell.Lease.claim/4` and `AshCell.Lease.holder/3` treat it as live while the `Date` on their own GET response is earlier than the lease's `Last-Modified` plus `ttl_ms` plus one second. Both timestamps come from the object store, through `AshCell.ObjectStore.get_object/2`, on the GET those functions already made. A lease with no `ttl_ms`, written before this change, is read from its `expires_at` by the reader's clock. New leases still write `expires_at` from the writer's clock, for readers running an older version.

## Context

`AshCell.Lease` wrote `expires_at` from the writer's wall clock, and each reader compared it with its own. DataLite measured an Android emulator whose BEAM lagged the device clock by 270s after its host slept. Every lease it renewed was already expired when it landed, so any other node asked to write took the cell. The txid fence still refused the phone's stale snapshot, but the phone lost its acknowledged, unshipped writes each time.

The `AshCell.Lease` moduledoc said clock skew is "not a correctness concern here". That holds for the bucket, because the txid fence protects it. It does not hold for a node's commits since its last shipment.

## Options considered

### Option A — a skew check in the application

The phone compares its clock with the store's `Date` before claiming. No library change. It protects only nodes that run the check.

### Option B — refuse to claim or renew beyond a skew bound

`AshCell.Lease` compares the node's clock with `Date` and refuses past a configured bound. Every node gets option A, but each node's clock is still trusted within the bound.

### Option C — expiry from the store's clock (taken)

The store already timestamps the lease when it accepts the write, and stamps each response. Comparing the two needs no node's clock and no new request. The cost is one-second resolution on both headers, and a dependency on the store setting `Last-Modified` on a conditional PUT.

## Decision and why

Option C, because the lease is already the authority and the store already timestamps it. It was verified against MinIO before building:

| Request | Status | `Last-Modified` after | `Date` on response |
|---|---|---|---|
| PUT `If-None-Match: *` | 200 | the PUT's second | yes |
| PUT `If-Match` (current etag), 2s later | 200 | moved to the new second | yes |
| PUT `If-Match` (stale etag) | 412 | unchanged | yes |
| GET of a missing key | 404 | none | yes |

Both headers are whole seconds. `Last-Modified` truncates the write time and `Date` truncates the read time, so the true age can exceed `Date - Last-Modified` by up to a second. The extra second in the comparison keeps a reader from taking a lease early. The cost is that a lease can stay live up to two seconds past its TTL, which is small against the default 30s.

A lease with `ttl_ms` whose GET carries no `Last-Modified` or `Date` raises `ArgumentError`. Falling back to the writer's `expires_at` would bring back the skew this removes, without saying so.

The writer no longer reads a wall clock for its own lease. `AshCell.LeaseRenewer` counts each TTL down on the monotonic clock from when it first sees the lease's etag.

## Consequences

- **What it rules out.** A lagging or leading node clock moving when other nodes see a lease expire.
- **What it makes worse.** Takeover after an expiry is up to two seconds later. Tests that let a lease expire now sleep 2.1s rather than a few milliseconds. A TTL under a few seconds is coarse.
- **What stays open.** Whether every S3-compatible store sets `Last-Modified` on a conditional PUT and sends `Date`. Neon Object Storage, which DataLite uses, was not checked from this repo. `AshCell.Ownership`'s `:bounded` mode still trusts the holder's own monotonic clock, as [ADR-14](ADR-14-bounded-read-staleness.md) says.
- **What now depends on it.** A released lease (ADR-32) has no owner, and `claim/4` takes it whatever its timestamps say.

## Evidence

- The MinIO probe ran on 2026-11-01 against `RELEASE.2025-10-15T17-29-55Z`, through Req with SigV4, with the results in the table above.
- `test/lease_test.exs`, describe "expiry measured by the store's clock". "a writer whose clock lags far beyond the TTL holds a live lease", "a reader whose clock runs far ahead still sees the lease live" and "a writer whose clock runs ahead does not extend its lease" all inject a clock an hour off through `:clock`. All three failed with expiry measured by `expires_at`. "a lease written with expires_at, before ttl_ms, is read by the reader's clock" covers the transition.

## Notes

Option C is option 2 in DataLite's `docs/designs/2026-11-01-phone-read-copy-and-write-lease.md`, section "Where lease expiry is measured". The friction note with the emulator measurements is `docs/friction/2026-11-01-a-lagging-clock-writes-leases-that-are-already-expired.md` in that repo.
