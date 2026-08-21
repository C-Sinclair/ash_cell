# ADR-18 — Carry the tenant in job args, and fail closed when it is missing

**Status:** accepted
**Date:** 2026-08-21
**Deciders:** Conor Sinclair
**Relates to:** [ADR-01](ADR-01-bind-tenants-per-process.md) · [ADR-02](ADR-02-bind-in-the-data-layer.md)

## The decision

`AshCell.Job` carries the tenant id in job args, as a plain serialisable term. A job that arrives
with no tenant id is cancelled outright, not retried.

## Context

Background jobs have no request boundary to bind at, and the ambient per-process binding
established in [ADR-01](ADR-01-bind-tenants-per-process.md) does not survive into an Oban job — an
Oban worker runs in whatever process the queue hands it, unrelated to whatever process bound a
tenant when the job was enqueued.

## Options considered

### Option A — rely on the enqueueing process's binding

What it buys: nothing, since Oban jobs run out-of-process from where they were enqueued. What it
costs: silently wrong, since the ambient binding is per-process and a job runs in a different
process entirely. Rejected as a non-starter, consistent with
[ADR-01](ADR-01-bind-tenants-per-process.md)'s finding that the binding does not survive
`Task.async`, `Ash.load` fan-out, or a job.

### Option B — carry the tenant id in job args

What it buys: a tenant id is a plain serialisable term, meaningful on any node, unlike a pid. The
job binds for itself on whatever node picks it up. What it costs: every job enqueue site must
remember to include the tenant id; a job written without it fails at run time rather than at
enqueue time. Chosen.

### Option C — route the job to the node that owns the cell

What it buys: the job would run where the cell already lives, avoiding a bind (and potential
hydration) on a node that does not otherwise have it resident. What it costs: this is a placement
decision, and placement is not something `AshCell.Job` resolves — it would need ownership
information the job layer does not have. Explicitly not done: "a job binds a cell on its own node,
which is only correct once ownership is resolved there. That's placement's problem." Left undone
rather than papered over.

## Decision and why

Option B is the only one that survives the process-boundary problem stated in
[ADR-01](ADR-01-bind-tenants-per-process.md): the handle that must travel with a job needs to be a
value binding can resolve on any node, not a pid, and a tenant id is exactly that value.
A job with no tenant id represents a structural absence, not a transient failure — retrying it
cannot produce a tenant id that was never enqueued, so it is cancelled rather than retried, failing
closed instead of retrying into the same absence indefinitely.

## Consequences

- **What it rules out.** Any job enqueued without an explicit tenant id in its args; any reliance on
  ambient binding surviving into a job.
- **What it makes worse.** Every job call site must pass the tenant id explicitly; there is no
  implicit fallback.
- **What stays open.** Job-to-owning-node routing is explicitly not solved — a job binds wherever it
  runs, which is only correct once placement is resolved separately. Background jobs remain on the
  project's unsolved-problems list.
- **What now depends on it.** `bound_tenant/0` was fixed to read the process dictionary directly
  rather than scanning the registry by pid, because scanning by pid is wrong the moment a cell
  restarts — this fix is required for `AshCell.Job`'s per-job binding to be correct.

## Evidence

- `AshCell.Job` carries the tenant id in job args (source location not given in evidence beyond the
  module name).
- `bound_tenant/0` fixed to read the process dictionary directly rather than scanning the registry
  by pid.

## Notes

Background jobs (Oban/AshOban) having no request boundary to route at remains on the project's
open-problems list, alongside the explicitly deferred placement question above.
