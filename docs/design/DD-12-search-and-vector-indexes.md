# DD-12 — Per-cell search and vector indexes

**Status:** draft
**Date:** 2026-08-24
**Decisions:** [ADR-15](../decisions/ADR-15-sqlcipher-from-the-system-build.md), [ADR-16](../decisions/ADR-16-isolation-is-blast-radius.md), [ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md), [ADR-03](../decisions/ADR-03-fork-ash-sqlite-narrowly.md)
**Lands in:** `lib/ash_cell/index/fts.ex`, `lib/ash_cell/index/vector.ex` (new), `mix cipher.check`

## What this is

Two indexes living inside the cell's own encrypted file: SQLite's built-in FTS5 for full-text
search, and `sqlite-vec` for approximate nearest-neighbour over embeddings. Both are maintained by
the cell's single writer, and both rebuild as a compaction
([DD-06](DD-06-append-log-and-compaction.md)).

The product this enables is per-tenant retrieval — search and RAG where one tenant's documents and
one tenant's embeddings are in one file that no other tenant's query can reach, because it is a
different file.

## What this proves

- FTS5 is available through the system SQLite build that
  [ADR-15](../decisions/ADR-15-sqlcipher-from-the-system-build.md) already requires, and works
  under SQLCipher — meaning the index is encrypted at rest with the same per-tenant key as the
  rows, with no additional key management.
- `sqlite-vec` loads as an extension into that same build, or it does not, and this doc records
  which. If loading an extension into the SQLCipher build fails, that is the finding and
  `mix cipher.check` should grow a check for it.
- Index maintenance is sound because it is the cell's writer doing it: no separate indexing
  pipeline, no eventual-consistency window between a write and its searchability, and no
  "reindex job" that can race the writer.
- A per-tenant vector index at realistic sizes (1k / 10k / 100k vectors) has a stated recall and
  latency, and the point at which a cell is the wrong home for the index is a number rather than
  an opinion.
- Both indexes ride the existing replication path untouched: they are pages in the file, so
  whole-file snapshots carry them and a restored or forked cell is searchable immediately with no
  rebuild ([ADR-12](../decisions/ADR-12-whole-file-snapshots-on-a-schedule.md)).

## Why it needs a cell

The isolation argument here is unusually clean, and must still be stated correctly. An embedding is
derived from the source text and leaks a great deal about it; a shared vector index with a
`tenant_id` filter puts every tenant's derived data in one structure, where correctness rests on
every query carrying the filter. In a cell it rests on the query reaching a different file.

That is **blast-radius reduction, not a regulatory advantage**
([ADR-16](../decisions/ADR-16-isolation-is-blast-radius.md)), and the pitch must not drift — the
node still holds the plaintext key to serve. The second, non-security reason is operational: a
per-tenant index is small, so ANN over it is fast and exact-enough, and rebuilding one tenant's
index is a bounded operation instead of a fleet-wide job.

## Non-goals

- **Not cross-tenant search.** No federated query, no fan-out-and-merge across cells. A
  fleet-wide search index re-comingles exactly the data the isolation pitch disclaims, and building
  it here would contradict the repo's own list of claims to avoid.
- **Not an embedding pipeline.** Embeddings arrive as vectors from the application. No model
  hosting, no chunking strategy, no re-embedding on model change.
- **Not a vector database.** One index type, one distance metric per index, no filtering-plus-ANN
  query planner beyond what `sqlite-vec` provides.
- **Not a ranking framework.** BM25 as FTS5 gives it; no learned reranking, no hybrid-score tuning
  beyond a documented example.
- **Not automatic indexing of every resource.** An index is declared, like a
  [DD-04](DD-04-read-cache.md) projection, because what is worth indexing is the application's
  knowledge.
- **Not exempt from the extension question.** If `sqlite-vec` cannot load under the SQLCipher
  build, the vector half does not ship and this doc records that instead of routing around it.

## Threat model

| Adversary | What they get | What stops them |
|---|---|---|
| A query missing a tenant filter | Nothing — there is no shared index to leak from | The binder resolves a cell key per statement; a wrong filter reads the wrong cell only if the *tenant* was wrong, which is a different bug. |
| Someone reading the disk | Index contents | SQLCipher, same key as the rows ([ADR-15](../decisions/ADR-15-sqlcipher-from-the-system-build.md)) — provided FTS5 and `sqlite-vec` store their data in the encrypted file and not in temp files. **This must be verified, not assumed**; SQLite temp storage is a real leak path. |
| Someone reading object-store snapshots | Index contents | The snapshot is the encrypted file, so the same key. Tiered blobs are not (see [DD-11](DD-11-collections.md)). |
| An embedding-inversion attack on a tenant's index | Approximate source text for *that tenant only* | The blast radius is one tenant. That is the actual claim and the limit of it. |
| The node operator | Everything | Nothing. The node holds the plaintext key to serve; `shroud` is the demo that addresses this and it does so differently. |

## Data model

Per declared index, inside the cell:

- **FTS5**: a virtual table `<resource>_fts` with the indexed columns, plus triggers or explicit
  writer-side upserts keeping it in step with the source table. Chosen deliberately in
  *Trade-offs*: explicit writer-side maintenance rather than triggers.
- **Vector**: a `vec0` virtual table `<resource>_vec` with `rowid` matching the source row and the
  embedding column, dimension fixed at declaration.

Neither is an Ash resource — both are queried through raw Ecto under `AshCell.with_tenant/2`, and
the results feed an `Ash.Query` filtered by the returned ids. This is a real ergonomic cost: two
round trips inside one cell, and no way to sort an Ash query by BM25 rank directly. Whether a
narrow fork change ([ADR-03](../decisions/ADR-03-fork-ash-sqlite-narrowly.md)) could expose
`MATCH` and `vec_distance` as expression calculations is an open question and a plausible upstream
contribution, since AshSqlite already supports expression calculations including sort.

## Trade-offs

- **Triggers vs writer-side maintenance.** Triggers are automatic and invisible, fire inside the
  transaction, and are hard to observe or migrate. Writer-side is explicit, testable, and can drift
  if a write path forgets. Chosen: writer-side through the data layer's seam, so *every* path —
  bulk, atomic, raw — is covered by the same place the binder already covers, which is the argument
  of [ADR-02](../decisions/ADR-02-bind-in-the-data-layer.md) reused.
- **Index in the cell vs a shared index with a tenant filter.** Shared is cheaper per byte and
  better for cross-tenant queries; in-cell is isolated and rebuildable per tenant. Chosen: in-cell,
  and cross-tenant search is a non-goal rather than a later feature.
- **`sqlite-vec` vs a Python/Rust sidecar vs pgvector on the global store.** A sidecar breaks the
  one-file story and the encryption story; pgvector puts embeddings back in a shared system.
  Chosen: `sqlite-vec`, contingent on it loading under SQLCipher.
- **Rebuild as compaction vs incremental only.** Incremental is cheap and drifts; a rebuild is the
  reconciler. Chosen: both, with the rebuild's disagreement with the incremental index logged.

## Measurements this must produce

Warm cell, median of 5, per-cell corpora at three sizes each:

- **FTS5 query latency** at 1k / 10k / 100k documents, against the DD-04 baselines so the numbers
  are comparable to something in the repo.
- **Vector search latency and recall@10** at 1k / 10k / 100k vectors at 384 and 1536 dimensions,
  recall measured against exact brute force. A **cliff**: state the vector count at which either
  latency crosses 50 ms or recall drops below 0.9, since that is the number that says "this cell is
  cut too coarse".
- **Write amplification**: insert latency with no index, with FTS5, with vector, with both.
- **File size** for each corpus size with and without each index, because snapshot cost is file
  size and this feature multiplies it — which directly affects
  [DD-05](DD-05-time-travel-and-forks.md)'s fork latency and should be cross-referenced there.
- **Snapshot and restore time** for an indexed cell versus an unindexed one of the same row count.
- **The temp-file check**, as a test not a number: confirm under load that FTS5 and `sqlite-vec`
  write no plaintext outside the encrypted file. `vcs`'s e2e script already makes a
  no-plaintext-in-the-WAL claim and this is the same check in a new place.

## Staging

1. **Probe: does FTS5 work under the SQLCipher system build?** A ~20-line test. Cheap, and
   everything else waits on it.
2. **Probe: does `sqlite-vec` load under that build?** Likewise, and a `mix cipher.check` addition
   whichever way it goes.
3. **FTS5 index declaration and writer-side maintenance**, raw-Ecto query helper. Checkable: a
   document is searchable in the same transaction that wrote it; a bulk write updates the index.
4. **The temp-file / plaintext check.**
5. **Vector index**, same shape, if stage 2 passed. Checkable: recall against brute force.
6. **Rebuild-as-compaction** on [DD-06](DD-06-append-log-and-compaction.md), plus measurements.
7. **A demo use**: `vellum` searching a document's own history, or `console` per-tenant search.
   `shroud` must **not** use this — its claim is that the server cannot read the data, and an index
   the server maintains contradicts that. Worth stating in `shroud`'s design doc too.

## Where it stops

- No cross-tenant search, by choice, permanently.
- BM25 and vector distance are not expressible in an Ash query, so ranked queries are two steps and
  cannot be sorted by Ash. Fixing it means a fork change that does not exist yet.
- Index size lands in the file, so it lands in every snapshot and every fork. A heavily indexed
  cell is a slower cell to move, and the numbers above are the price list.
- `sqlite-vec` is approximate; recall is a measured property, not a guarantee, and it changes with
  index parameters this doc does not tune per tenant.
- No re-embedding story: change the embedding model and every cell's index is stale, with no
  fleet-wide reindex tool here.
- Isolation is blast radius, not confidentiality from the operator
  ([ADR-16](../decisions/ADR-16-isolation-is-blast-radius.md)). The node holds the key.
- No hybrid search scoring beyond a documented example.

## Open risks

- **Stage 2 may fail.** Loading an extension into a SQLCipher build has real failure modes
  (`enable_load_extension`, static builds, platform differences), and the whole vector half depends
  on it. `EXQLITE_USE_SYSTEM` already fails *silently* when misconfigured, so this needs to be a
  `cipher.check` assertion rather than a runtime surprise.
- **The temp-file leak path is the one that would embarrass the isolation claim.** FTS5 merges and
  large sorts can spill; if they spill unencrypted, the claim is wrong until
  `PRAGMA temp_store = MEMORY` is enforced and measured for memory cost.
- **Per-tenant index cost may be the wrong economics** for a fleet of many small tenants: 10 000
  cells each carrying a vector index has a fixed per-index overhead a shared index amortises. The
  file-size measurement will show it, and the honest conclusion may be that this suits few-large
  tenants only.
- Whether ranked search without Ash-level sorting is usable enough for a demo to be built on it.
