# ADR-10 — Stop serving a cell once a shipment proves it is not ours

**Status:** corrects an earlier belief (previous behaviour was log-and-continue)
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-08](ADR-08-fence-by-shared-txid.md) · [ADR-11](ADR-11-simulate-the-protocol-only.md)

## The decision

On a refused durability shipment, quarantine the cell key, force-close the cell process
(`force: true`), and drop the lease. Recovery is explicit, ordered, and manual: re-claim →
restore → release.

## Context

Previous behaviour: a refused shipment logged a warning and the node carried on serving. A
refused shipment is the only local signal that another node now owns the cell — by the fencing
mechanism in [ADR-08](ADR-08-fence-by-shared-txid.md), a `{:error, :precondition_failed}` on a
durability write means a successor has already claimed and written past this node's high-water
mark. Continuing to serve after that signal means serving data this node no longer has any claim
to own.

This is the concrete implementation of the DST invariant `fenced_node_stops_acknowledging`, which
production actually failed before this fix.

## Options considered

### Option A — quarantine only

Mark the cell key as fenced but leave the process and lease alone. Cost: `ensure_started/1` checks
the registry first and hands back a resident pid without consulting quarantine, so a fenced cell
would keep serving through the existing process even though its key is marked.

### Option B — close only

Force-close the process without quarantining the key. Cost: a fenced-but-untracked cell can be
silently reactivated by the next request against the same stale file, since nothing records that
this cell key must not be re-opened.

### Option C (chosen) — quarantine and close together, plus drop the lease

Quarantine blocks reactivation via `ensure_started/1`; force-close stops the process that is
already running. `force: true` is required because waiting for quiescence would wait on work that
must not finish. Dropping the lease matters too — otherwise the node keeps renewing ownership it
does not have. Cost: any in-flight work on the cell is abandoned rather than drained, and recovery
requires a manual, explicit sequence rather than an automatic retry.

## Decision and why

Quarantine alone and close alone each fail for a different reason — one leaves a path back in
through the registry, the other leaves a path back in through the file itself — so both are
necessary, and neither is redundant with the other. The choice to fail closed rather than log and
continue follows directly from what each failure mode costs: "refusing to serve is recoverable and
visible; serving data this node no longer owns is neither." A refused shipment is not a transient
error to retry past — it is proof, not a suspicion.

## Consequences

- **What it rules out.** Log-and-continue as a response to a refused shipment, and any recovery
  path that silently resumes serving without an explicit re-claim.
- **What it makes worse.** In-flight work on a quarantined cell is abandoned, not drained — a
  refused shipment during active traffic produces visible failures immediately rather than a
  graceful wind-down.
- **What stays open.** Recovery is manual by design; there is no automatic re-claim policy, and
  none is proposed here.
- **What now depends on it.** [ADR-11](ADR-11-simulate-the-protocol-only.md)'s
  `fenced_node_stops_acknowledging` invariant is validated against this behaviour; it is the
  invariant production had previously violated.

## Evidence

- Commit: `3b6197c`, following `c504c91`.
- DST invariant: `fenced_node_stops_acknowledging`, in `test/dst_stage0_test.exs` (see
  [ADR-11](ADR-11-simulate-the-protocol-only.md)).

## Notes

None beyond what is stated above — the evidence file records this ADR concisely and does not carry
additional test names or measurements for it specifically, beyond the invariant it implements.
