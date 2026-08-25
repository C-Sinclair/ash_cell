# DD-10 — Tenant-local graph

**Status:** draft
**Date:** 2026-08-24
**Decisions:** [ADR-19](../decisions/ADR-19-the-cell-cut-is-a-choice.md), [ADR-03](../decisions/ADR-03-fork-ash-sqlite-narrowly.md), [ADR-16](../decisions/ADR-16-isolation-is-blast-radius.md)
**Lands in:** `lib/ash_cell/graph.ex` (new), possibly a narrow fork change for recursive CTEs

## What this is

Edges as rows and traversal as a SQLite recursive CTE, inside a cell. Ancestors, descendants,
reachability, shortest path on small graphs, and cycle refusal — for the graphs that are already
tenant-shaped: an org hierarchy, a folder tree, a commit DAG, a permission graph.

The interesting application is **tenant-local ReBAC**: Zanzibar-style relationship tuples living in
the tenant's own file, so the overwhelming majority of authorization checks resolve as a local
B-tree walk with no network hop.

## What this proves

- Recursive traversal works through the fork's data layer, or — if it does not — exactly which seam
  refuses it and what the narrow fix is. Either outcome is a result worth having on record.
- A permission check over a tenant's own relationship graph costs a local query, and the number is
  comparable to a single indexed row read rather than to a network round trip.
- A cycle-refusing edge insert is atomic: the reachability check and the insert are one
  transaction, so two concurrent inserts cannot each pass a check and jointly create a cycle. This
  is the same read-modify-write argument as [DD-06](DD-06-append-log-and-compaction.md)'s
  compaction, in a second setting — which is the point.
- Traversal depth and fan-out have a stated cost curve, including where an unbounded traversal
  becomes a denial-of-service on the cell's single connection.

## Why it needs a cell

Two reasons, one strong and one honest.

The strong one is the cycle-free invariant. "Insert this edge if it does not create a cycle" is a
read-modify-write over the whole reachable set, and on a shared table two concurrent inserts can
both pass and jointly create the cycle. Serialising it needs a lock over the graph — which
AshSqlite has no primitive for at all, and which a cell provides by construction.

The honest one is latency, and it is a *consequence* rather than a requirement: a graph in the
tenant's own file is a local query. That is real but it is not isolation, and this doc should not
dress it up as one ([ADR-16](../decisions/ADR-16-isolation-is-blast-radius.md)).

Where the cell is cut is the constraint that makes or breaks this: a graph that stays inside one
cell is fast and safe; a graph whose edges cross tenants is not this feature.

## Non-goals

- **Not a graph database.** No property graph, no query language, no index-free adjacency, no
  Gremlin or Cypher. A handful of traversal shapes as functions.
- **Not cross-cell.** An edge between two cells cannot be traversed, checked for cycles, or
  transacted. This is the same refusal as [ADR-05](../decisions/ADR-05-refuse-cross-cell-transactions.md)
  and it removes a large class of real authorization models — cross-tenant sharing chief among them.
- **Not a full Zanzibar.** No userset rewrites, no schema language, no zookies, no consistency
  tokens. Relationship tuples and a reachability check.
- **Not large graphs.** Cells are small; a million-edge graph in a cell is a signal the cut is
  wrong.
- **Not an aggregate over a traversal.** AshSqlite has no aggregates and no lateral joins, so
  "count of descendants" is an expression calculation or raw Ecto under `with_tenant/2`, and the
  ergonomics of that are a stated cost rather than a thing to be fixed here.
- **Not a policy engine.** It answers "is B reachable from A"; turning that into an Ash policy is
  the application's.

## Data model

One table per graph, `<name>_edges`: `from_id`, `to_id`, `kind`, `meta`, `inserted_at`, with a
composite primary key on `(from_id, to_id, kind)` and a second index on `(to_id, kind)` so
reverse traversal is not a scan. For ReBAC the same table with `kind` as the relation
(`owner`, `editor`, `parent`) and ids as `type:id` strings.

Traversal is a recursive CTE with a depth cap in the query itself, not applied afterwards, so a
pathological graph cannot make the query unbounded. Whether that CTE can be expressed through the
data layer at all is stage 1's question; the fallback is raw Ecto under `AshCell.with_tenant/2`,
which is what that function is for.

Optionally a **closure table** — materialised transitive reachability, maintained in the same
transaction as the edge insert — trading write cost for O(1) checks. Only if the measurement says
recursive CTEs are too slow, and it is a [DD-06](DD-06-append-log-and-compaction.md)-shaped
read-modify-write when it arrives.

## Trade-offs

- **Recursive CTE vs closure table.** CTE: cheap writes, cost per read scaling with depth and
  fan-out. Closure: O(1) reads, writes proportional to reachable-set size, and a bigger file.
  Chosen: CTE first, closure only if a measured check latency justifies it. The measurement is
  named below precisely so this is not decided by taste.
- **Through the data layer vs raw Ecto.** Going through Ash keeps policies, calculations, and the
  binder in play; raw Ecto certainly works. Chosen: attempt Ash, fall back to raw Ecto under
  `with_tenant/2`, and if a *narrow* fork change makes the Ash path work, take it
  ([ADR-03](../decisions/ADR-03-fork-ash-sqlite-narrowly.md)) since a recursive-CTE fragment is
  plausibly upstreamable.
- **Cycle refusal always vs opt-in.** Always costs a reachability check per insert. Chosen: opt-in
  per graph, because a DAG-by-construction graph (a commit DAG) should not pay for it.
- **`type:id` strings vs typed columns for ReBAC.** Strings are Zanzibar-shaped and untyped;
  columns are typed and rigid. Chosen: strings, as the tuple model is the borrowed part.

## Measurements this must produce

Warm cell, median of 5, on generated graphs:

- **Check latency** (is B reachable from A) at depth 1 / 3 / 10 and fan-out 2 / 10 / 100, against
  the DD-04 pointer-read baseline (17.0 µs). A **cliff**: state the depth × fan-out product at
  which a check crosses 1 ms, since that is what decides the closure table.
- **The same check against a network-hop equivalent** — one number, a local Postgres round trip —
  so the "local query" claim has a comparison rather than an adjective.
- **Edge insert cost** with and without cycle refusal, at graph sizes 100 / 10 000 / 100 000 edges.
- **Worst-case traversal**: a deliberately pathological graph (complete-ish, or a long chain) with
  the depth cap in place, showing the cap bounds the cost and reporting the bound.
- **Closure-table write amplification**, if stage 4 is reached: bytes and write latency versus the
  CTE version on the same graph.

## Staging

1. **Probe first, before any design work is trusted.** A ~30-line test establishing whether a
   recursive CTE reaches SQLite through the fork's data layer, and if not, where it stops. This is
   the repo's own rule — answer a question with a small probe — and everything below depends on
   the answer.
2. **Edges table and traversal functions** (`ancestors/3`, `descendants/3`, `reachable?/3`) with a
   depth cap. Checkable: known answers on a fixture graph; the cap holds on a cycle.
3. **Cycle-refusing insert.** Checkable: the atomicity property — concurrent inserts that would
   jointly create a cycle, asserting one fails.
4. **ReBAC tuples and `check/4`.** Checkable: a small permission model with the standard cases
   (direct grant, inherited via parent, revoked).
5. **Measurements**, then the closure table only if the numbers demand it — and if they do not,
   record that and delete the option.
6. **A demo use**: `vcs` commit-DAG ancestry, which is a real DAG with a real traversal, rather
   than a synthetic org chart.

## Where it stops

- One cell. Cross-tenant sharing — the single most-requested real ReBAC feature — is out, and
  saying so plainly matters more than the rest of this document.
- No aggregates over traversals through Ash; that is raw Ecto and it is awkward.
- Small graphs only, with the size at which it stops being viable named by the measurement rather
  than guessed.
- An unbounded traversal can occupy the cell's single connection and degrade every other query for
  that tenant. The depth cap bounds it; it does not eliminate the class.
- No sub-graph isolation within a cell: everything in the file is traversable, so "may this user
  traverse this edge" is the application's, and a permission graph that must itself be
  permission-checked is not modelled.
- Nothing here caches. A hot permission check re-queries, unless the application puts it behind a
  [DD-04](DD-04-read-cache.md) projection.

## Open risks

- **Stage 1 may fail.** If recursive CTEs cannot reach SQLite through the fork or through raw Ecto
  under `with_tenant/2`, this feature is a much smaller thing (single-level edges) and the doc
  should be cut down rather than kept aspirational.
- **The cross-cell limit may make ReBAC not worth shipping.** If the honest answer is "this handles
  intra-tenant checks and real products need cross-tenant sharing", then the ReBAC framing should
  be dropped and only the DAG traversal kept. Deciding that needs a real model, not a synthetic one.
- Whether the closure table's read-modify-write is materially different from
  [DD-06](DD-06-append-log-and-compaction.md)'s compaction, or whether it should just *be* a log
  fold — worth checking before writing it twice.
