# ADR-32 — Release a lease by a conditional write, not a DELETE

**Status:** accepted
**Date:** 2026-11-01
**Deciders:** Conor Sinclair
**Relates to:** `AshCell.Lease`, `AshCell.Drain`, [ADR-08](ADR-08-fence-by-shared-txid.md), [ADR-09](ADR-09-snapshot-before-releasing-the-lease.md)

## The decision

`AshCell.Lease.release/2` overwrites `lease.json` with an expired lease that has no owner, using a PUT with `If-Match` on the etag the releasing owner holds. It does not delete the object. A release whose etag no longer matches returns `{:error, :precondition_failed}` and leaves the object alone. `AshCell.Lease.holder/2` reads an ownerless lease as `{:ok, nil}`, the same answer it gives for a missing one, and `AshCell.Lease.claim/4` takes it over with `If-Match`, as it does an expired lease.

## Context

`release/2` used to `DELETE` the lease with no condition. DataLite's dogfooding found that a displaced owner that drains after its lease was taken deletes its successor's lease. The successor keeps writing, but a third node can then claim with a fresh generation, so two nodes believe they own the cell. The txid fence still refuses one of them, but only after the refused node has acknowledged writes it can no longer ship.

The obvious fix is `DELETE` with `If-Match`. It does not work on the store this repo tests against.

## Options considered

### Option A — conditional DELETE

`DELETE` with `If-Match: <etag>`. It keeps "no object" as the released state. MinIO `RELEASE.2025-10-15T17-29-55Z` ignores the header. A DELETE with a stale etag returned 204 and removed the object, and so did a DELETE of a missing key. A release built on it would pass every review and fence nothing. Rejected.

### Option B — read, compare, then DELETE

GET the lease, compare its etag, then delete. The successor's claim can land between the GET and the DELETE, which is the same bug with a smaller window. Rejected.

### Option C — conditional PUT of an ownerless, expired lease (taken)

A PUT with `If-Match` is the primitive the rest of the design already relies on (`AshCell.ObjectStore`), and MinIO honours it. Its cost is that a released cell keeps a `lease.json`, so "no lease object" no longer means "never claimed or released". `holder/2` hides that difference from callers.

## Decision and why

Option C, because it is the only one of the three that is atomic on MinIO. The generation counter already lives in its own object, so a lease body that outlives its owner changes nothing about generation allocation. The tombstone keeps `generation` and `txid` for an operator reading the bucket. `claim/4` reads neither from it.

## Consequences

- **What it rules out.** Treating a missing `lease.json` as the only released state. Code that wants to know whether a cell is held must call `holder/2`.
- **What it makes worse.** One small object per released cell stays in the bucket. `AshCell.Branch` still deletes a branch's lease when the branch itself is deleted, which is unaffected.
- **What stays open.** Whether AWS S3 honours `If-Match` on DELETE was not checked. If every supported store does, Option A becomes available again.
- **What now depends on it.** `AshCell.Drain.drain_cell/3` fences the cell when its release is refused, because a refusal means another owner holds the lease.

## Evidence

- `test/lease_test.exs`, "a displaced owner's release leaves its successor's lease alone": before this change `release/2` returned `:ok`, and `holder/2` then returned `nil` for a lease another node held.
- `test/lease_test.exs`, "a holder's release lets the next claim take the cell at once".
- The DELETE probe ran against MinIO `RELEASE.2025-10-15T17-29-55Z` on 2026-11-01: PUT, PUT again, then DELETE with the first etag (quoted and unquoted) returned 204 and the object was gone.

## Notes

Found by DataLite, a bookmark store built on AshCell, while adding lease renewal (`docs/friction/2026-11-01-ash-cell-gaps-found-adding-renewal.md` in that repo, item 3).
