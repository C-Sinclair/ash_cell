# Design docs

One document per unit of work: what gets built, what it proves, and where it stops. Start from
[`DD-00-TEMPLATE.md`](DD-00-TEMPLATE.md).

A design doc describes the *system* — how the pieces fit and what the whole thing is for. When a
choice inside it had a real alternative that lost, that belongs in an
[ADR](../decisions/README.md) instead, linked from here rather than re-argued. The two documents
answer different questions: this one "what are we building and how will we know it worked", the
ADR "why is it like this".

Four sections carry the weight and the template will not let you drop them: **what this proves**,
**non-goals**, **measurements this must produce**, and **where it stops**. Naming the measurements
before the work is what stops a convenient subset being reported after it — shroud's did exactly
that, and the number came back and reversed the design.

| Doc | Covers | Status |
|---|---|---|
| [DD-01](DD-01-cell-runtime.md) | Cell lifecycle: activation, eviction, quarantine, drain, quiescence, holders | built |
| [DD-02](DD-02-replication-and-ownership.md) | Leases, generations, txid fencing, snapshot and restore, periodic shipping | built |
| [DD-03](DD-03-tenant-binding.md) | How a query reaches the right database: cell keys, the binder, the fork's seam, transactions | built |
| [DD-04](DD-04-read-cache.md) | The `persistent_term` read cache and its epoch bracketing | built |
| [DD-05](DD-05-time-travel-and-forks.md) | Reading a cell at a past txid, and copy-on-write forks of one | draft |
| [DD-06](DD-06-append-log-and-compaction.md) | The append log and its fold-snapshot-truncate compaction | draft |
| [DD-07](DD-07-durable-timers.md) | Per-cell durable timers, fired by the cell that owns them | draft |
| [DD-08](DD-08-durable-execution.md) | Tenanted durable execution: workflows, history, outbox | draft |
| [DD-09](DD-09-counters-and-quotas.md) | Exact counters, quotas, and rate limits | draft |
| [DD-10](DD-10-tenant-local-graph.md) | Edges, traversal, and tenant-local ReBAC | draft |
| [DD-11](DD-11-collections.md) | CAS, bounded cache, queue, content-addressed tree | draft |
| [DD-12](DD-12-search-and-vector-indexes.md) | FTS5 and `sqlite-vec` inside the cell | draft |
| [DD-13](DD-13-durable-streams.md) | Offset-keyed segments in the object store, and resume across the writer's death | building |

DD-01 to DD-04 were written *after* the code, to record what exists. Anything new should get its
design doc first.

## Demos

Each demo keeps its own design doc beside its README, because a demo is a unit of work in the same
sense:

- [`demos/shroud/docs/design.md`](../../demos/shroud/docs/design.md) — one cell per user, with data
  the server cannot read
- [`demos/rollout/docs/design.md`](../../demos/rollout/docs/design.md) — one cell per release
  channel
- [`demos/relay/docs/design.md`](../../demos/relay/docs/design.md) — one cell per stream, and an
  offset that outlives the process that issued it

## Related

- [`docs/spec.md`](../spec.md) — the living design of the library as a whole, edited in place
- [`docs/dst.md`](../dst.md) — the deterministic simulation spec
- [`docs/decisions/`](../decisions) — the decisions these rest on
