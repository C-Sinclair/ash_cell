# ADR-33 — Renew leases from one process per fleet, and release through it

**Status:** accepted
**Date:** 2026-11-01
**Deciders:** Conor Sinclair
**Relates to:** `AshCell.LeaseRenewer`, `AshCell.Manager`, `AshCell.Drain`, [ADR-08](ADR-08-fence-by-shared-txid.md), [ADR-10](ADR-10-fail-closed-on-a-refused-shipment.md), [ADR-14](ADR-14-bounded-read-staleness.md), [ADR-32](ADR-32-release-a-lease-by-conditional-write.md)

## The decision

`AshCell.LeaseRenewer`, one process per fleet started after `AshCell.Manager`, renews every lease the manager holds once `AshCell.Ownership.renew_due?/1` is true for it. It records each renewal with `AshCell.Manager.renewed/3`, which replaces `etag`, `expires_at` and `ttl_ms` and keeps the txid. A renewal refused because another owner holds the lease fences the cell with `AshCell.Manager.fence/1`. `AshCell.Drain` releases leases through `AshCell.LeaseRenewer.release/2`, so a release and a renewal of one lease never run at once.

## Context

`AshCell.Lease.renew/3` and `AshCell.Ownership.renew_due?/1` existed and nothing called them. Every lease claimed through `AshCell.claim/2` expired after its TTL while the node kept serving and shipping the cell, because shipping checks the snapshot key, not the lease. DataLite saw another node take its cell 30 seconds after every claim, and worked around it with its own renewal process, which recorded renewals with `:sys.replace_state/2` on the manager.

## Options considered

### Option A — a timer in each `AshCell.Cell`

The cell already has its store and dies with its lease. It loses on two counts. Fencing from inside the cell deadlocks: `AshCell.Manager.fence/1` closes the cell with `DynamicSupervisor.terminate_child/2`, which waits for the very process making the call. And a release from `AshCell.Drain` would still have to be serialised with the cell's renewal, which means a call into the cell carrying a network PUT.

### Option B — one renewer per fleet (taken)

One process holds no lease state of its own beyond a monotonic deadline per cell. The manager stays the record of what this node holds. Releases are calls into the same process, so they queue behind a tick's renewals. Renewals within a tick run concurrently, sixteen at a time.

### Option C — renew inside `AshCell.Manager`

The manager already serialises lease bookkeeping. A PUT inside it would block every `ensure_started/1` and `claim_txid/1` on the node for the length of a round trip to the store. Rejected.

## Decision and why

Option B. It avoids the deadlock in A and the blocking in C, and puts release and renewal in one queue.

The renewer computes each lease's remaining time from `expires_at` against this node's wall clock, because this node wrote that value. It then counts down on the monotonic clock. A renewal writes the manager's current txid into the lease body. `AshCell.Lease.claim/4` no longer reads that field, so it is only there for an operator reading the bucket.

## Consequences

- **What it rules out.** A lease that silently lapses while its node serves the cell, as long as the store answers.
- **What it makes worse.** One PUT per held lease every two thirds of a TTL. At the default 30s TTL and 256 resident cells that is about 13 PUTs a second per node, which is an estimate and was not measured.
- **What stays open.** A renewer that cannot reach the store logs and retries each tick, and the lease expires on schedule. Nothing then stops the node serving reads, unless the application checks `AshCell.Ownership`. Clock skew between nodes still decides when another node treats the lease as expired; `docs/spec.md` §8 records that as an open question.
- **What now depends on it.** `AshCell.Drain.drain_cell/3` requires the renewer to be running to release a lease.

## Evidence

- `test/lease_renewal_test.exs`. With `AshCell.LeaseRenewer` taken out of `AshCell.Supervisor`, "a held lease outlives its TTL", "a node whose lease was taken is fenced on its next renewal" and "draining a renewed cell releases its lease without fencing it" fail. The last one fails because the drain cannot reach the renewer.
- The race between a release outside the renewer and a renewal was not reproduced. Fifteen runs of the drain test with the release moved out of the renewer all passed. The serialisation is argued from the code, not measured.

## Notes

Found by DataLite (`docs/friction/2026-11-01-lease-is-never-renewed.md` and `2026-11-01-ash-cell-gaps-found-adding-renewal.md` in that repo). Its `Datalite.LeaseKeeper` is the prior art this replaces.
