# AshCell — Design Spec & Plan (rev 2)

**Status:** draft, revised against two adversarial/verification reviews
**Date:** 2026-08-05
**Verified against:** ash 3.31.0, ash_postgres 2.11.0, ash_sql 0.6 (read from local deps);
ash_sqlite main; exqlite; Litestream v0.5; AWS/R2/Tigris conditional-write docs.

---

## 0. What changed in rev 2

Three findings reshape the plan. Two make it smaller, one makes it more honest.

1. **The per-query repo override already exists.** `AshSql.dynamic_repo/3` checks
   `query.__ash_bindings__.context.data_layer.repo` (and the changeset equivalent)
   *before* falling back to the DSL-declared repo. So a tenant's repo pid can be injected
   with `Ash.Query.set_context(%{data_layer: %{repo: pid}})`. This is the escape hatch
   AshPostgres uses for read replicas.
   **Consequence: we probably do not need a wrapper data layer at all, and we must not use
   `put_dynamic_repo/1`.** The context override travels with the query struct; the process
   dictionary does not. Every `Task.async` / `Ash.load` fan-out / Oban concern in rev 1
   §4.3 is dissolved by choosing the right mechanism.
2. **RPO=0 is celld's claim, not Litestream's.** Litestream v0.5's RPO is roughly its L0
   upload interval (~1s). Achieving RPO=0 means gating the client ack on the segment PUT,
   which drags in the entire pre-ack observability problem (§4). Rev 1 conflated the two.
   **This is now a deliberate fork in the road, not an assumption.**
3. **AshSqlite has no aggregates and no transactions** (`can?(_, :transact) → false`,
   `can?(_, {:aggregate, _}) → false`). Verified in source. The rev 1 "zero resource
   changes" claim is false and is withdrawn.

## 1. What AshCell is

An Ash data layer giving **database-per-tenant on SQLite**: one encrypted SQLite file per
tenant, owned by one Elixir process at a time, replicated to S3-compatible object storage.

The two properties worth building for:

- **Blast-radius isolation.** A tenant's data is a separate encrypted file, not a `WHERE`
  clause. An application-level authorization bug cannot leak across tenants because there
  is no shared table to leak from. Deletion, export, and per-tenant restore are file
  operations.
- **N+1 immunity.** Compute is colocated with storage, so relationship loading and deep
  `load` graphs cost effectively nothing. This is the honest performance pitch — not
  "1µs vs 1ms point reads", which is real but swamped by network RTT in any actual UX.

### What we will not claim

Rev 1 overclaimed and it needs correcting before it reaches a pitch deck:

- **HIPAA does not require physical isolation.** The Security Rule is access controls,
  audit, and encryption. Auditors accept row-level tenancy routinely. Physical isolation
  is a strong *enterprise sales* position and a genuine blast-radius reduction. It is not
  a regulatory advantage and must not be sold as one.
- **BYOK here is not confidential computing.** The node holds the plaintext key to serve;
  decrypted pages sit in the page cache. Revoking a key stops future hydrations; it does
  not eject a resident cell. Same trust model as Postgres with per-tenant KMS keys.
- **The analytics plane re-comingles the data.** Cross-tenant DuckDB/Iceberg over S3
  snapshots rebuilds exactly the shared PHI store the isolation pitch disclaims. It needs
  its own controls, key handling, and deletion story. This is where an auditor will look.

## 2. The replication fork in the road

This is now the single biggest design decision, and it should be made before Stage 2.

| | **Path A — Litestream sidecar** | **Path B — in-BEAM LTX, ack-gated** |
|---|---|---|
| RPO | ~1s (L0 interval) | 0 |
| Write latency | local fsync (~1ms) | ~90ms (celld's own published figure) |
| Split-brain protection | **Already built** — v0.5 uses S3 conditional writes as a time-based lease | We build it (conditional segment PUT keyed by TXID) |
| exqlite NIF work | none | **required** — no `wal_hook`, no commit hook, no session extension, no backup API exposed |
| Elixir LTX implementation | none | required (none exists; format is simple, binary-pattern-match friendly) |
| Pre-ack side-effect problem | **does not arise** | must re-plumb Ash notifiers/hooks, LiveView diffs, PubSub, Oban enqueues into a post-ack phase |
| Scales to many DBs | explicit v0.5 design goal ("hundreds or thousands of databases" in one directory, one supervising process) | our problem |
| Effort | weeks | months |

**Recommendation: Path A for v1.** Almost the entire adversarial-review nightmare —
uncommittable local transactions, retry ambiguity between "my PUT succeeded" and "I was
fenced", suicide-on-ambiguity semantics, and the requirement that *no observer ever sees a
pre-ack transaction* — is a consequence of choosing RPO=0. Drop that requirement and it
evaporates. A ~1s RPO is acceptable for a very large fraction of real workloads, and
Litestream already solved the lease problem we were planning to solve ourselves.

Path B stays on the roadmap as a research track for workloads that genuinely cannot lose
one second of writes. It should be entered deliberately, with the side-effect pipeline
designed first and tested adversarially, never drifted into.

## 3. Revised staging

| Stage | Delivers | Effort |
|---|---|---|
| **0. Upstream** | PR to ash_sqlite for `can?(:multitenancy)` + `set_tenant/3` (open issue [#127](https://github.com/ash-project/ash_sqlite/issues/127) asks for exactly this) | days |
| **1. Cells** | Per-tenant repo instances via the Ash context override, cell lifecycle, routing, encryption, migration, global/tenant split, **the demo** | ~1 week |
| **2. Replication (Path A)** | Litestream v0.5 sidecar, per-tenant config, restore-on-activation, PITR | ~2 weeks |
| **3. Placement** | Multi-node routing, hydration orchestration, admission control, deploy/rebalance handling | ~3 weeks |
| **4. Research (Path B)** | exqlite NIF additions, Elixir LTX, ack-gated commit, post-ack side-effect pipeline | open-ended |

Stage 0 is worth doing first regardless of whether the rest proceeds: it's small, upstream
demand is documented, and it's a better first contribution to be known for than a demo.

## 4. Stage 1 spec

### 4.1 Mechanism

**Do not use `put_dynamic_repo/1`.** Resolve the tenant's repo pid and inject it via
`Ash.Query.set_context(%{data_layer: %{repo: pid}})` / the changeset equivalent, applied
from a resource-level `prepare`/`change` or a thin Spark extension reading `query.tenant`.
`Ash.ToTenant` is the protocol for turning a rich tenant value into the term the data layer
sees.

This means AshCell is plausibly **an extension plus a runtime**, not a data layer
reimplementation. Confirming that in the first two days is the highest-value thing in
Stage 1.

### 4.2 Modules

| Module | Responsibility |
|---|---|
| `AshCell.Extension` | Spark extension; sets the repo override in query/changeset context from the tenant |
| `AshCell.Cell` | GenServer owning one tenant's `Repo.start_link(name: nil, database: path)` instance |
| `AshCell.Registry` / `Manager` | `tenant_id -> pid`; `DynamicSupervisor` with bounded resident set, LRU eviction, `max_resident_cells` / `max_rss_mb` |
| `AshCell.Router` | Plug + LiveView `on_mount` resolving tenant → cell |
| `AshCell.Migrator` | Per-cell `user_version` check and migration, with quarantine on failure |
| `AshCell.Vault` | Per-tenant key custody, SQLCipher key at open |
| `AshCell.Telemetry` | Activation, hydration, eviction, query/write duration, resident count, RSS |

### 4.3 Encryption — VERIFIED CLEAN, no fork

exqlite supports linking a system SQLCipher since 0.9, and `ecto_sqlite3` passes the key
through as a plain repo option. Setting `EXQLITE_USE_SYSTEM` makes `make_precompiler`
return `nil`, bypassing the precompiled-NIF path and compiling the (engine-agnostic) NIF
against libsqlcipher:

```bash
export EXQLITE_USE_SYSTEM=1
export EXQLITE_SYSTEM_CFLAGS=-I/usr/local/include/sqlcipher
export EXQLITE_SYSTEM_LDFLAGS="-L/usr/local/lib -lsqlcipher"
mix deps.compile exqlite --force
```

Crucially, `Exqlite.Connection.do_connect/1` calls `set_key/2` **first**, before
`set_custom_pragmas` and before journal_mode — with a source comment noting that setting
the key is the only thing that works on an encrypted database. SQLCipher's
key-before-anything requirement is therefore satisfied by construction, and per-tenant keys
fall out of per-tenant repos for free:

```elixir
Repo.start_link(name: nil, database: tenant_path, key: tenant_key)
```

`custom_pragmas:` runs immediately after the key, which is where `cipher_*` options and
`PRAGMA rekey` (key rotation) go.

**The cost is deployment, not code.** Precompiled NIFs are off, so every build environment
(dev macOS, CI, Docker builder) needs a C toolchain plus SQLCipher headers. Worse, if the
env vars are missing at compile time you silently get plain SQLite that cannot open
encrypted files — so a boot-time assertion on `PRAGMA cipher_version` returning non-empty
is mandatory, not optional hygiene.

Licence: SQLCipher Community Edition is BSD-style, no fee. (SEE is $2,000 perpetual and
unnecessary here.) Expect ~5–15% overhead; measure it. No published large-scale Elixir
production use was found, so Stage 1 should include its own soak test.

### 4.4 Runtime parameters (verified defaults to design against)

- **`pool_size: 1` per tenant repo.** ecto_sqlite3 defaults to 5; community experience is
  that higher pools produce "database is busy" errors. Writes serialize on SQLite's writer
  lock regardless, so the GenServer and the pool are doing the same job — keep one.
- **exqlite uses dirty NIF schedulers**, so no main-scheduler blocking, but **dirty-IO
  saturation is the real contention limit** (default 10; tune `+SDio`). Storage isolation
  is not compute isolation — one tenant's slow query is felt by others.
- **~2MB SQLite page cache per connection** (`cache_size` −2000), boundable via PRAGMA.
  Budget a few MB per *resident* tenant and treat resident density as a first-class
  capacity dimension. Hibernation must close the connection or it doesn't hibernate.

### 4.5 What breaks — the honest constraint list

This replaces rev 1's "zero changes" claim.

**AshSqlite gaps (verified in source):**

| Feature | Available |
|---|---|
| Expression calculations, incl. sort | yes |
| Joins / filters on relationships | yes, **same data layer and same repo only** |
| Upsert, `exists` subqueries | yes |
| **Aggregates** (`count`, `sum`, `first`, aggregate filter/sort) | **no** |
| **Transactions** (`:transact`) | **no** |
| Lateral joins, `distinct`, locks | no |

`:transact → false` is the one with teeth: Ash will not wrap actions in a transaction, so
multi-step actions and bulk operations are not atomic, and an after-hook failure leaves the
primary write committed. **This is a data-integrity semantics change, and it must be
surfaced loudly**, not buried in a capability table.

**Cross-boundary (global Postgres ↔ tenant cell):** relationship *loading* works via
separate queries and in-memory stitching. Filtering, sorting, and aggregating tenanted rows
by a global attribute cannot be pushed to SQL. Design response: denormalise the attributes
you filter/sort by into the cell at write time.

**Consequence for the pitch:** the portable surface is "resources using expression
calculations, no aggregates, no transaction-dependent hooks." A Stage 1 deliverable is an
audit mix task that tells you which of your resources qualify.

### 4.6 Known-unanswered operational problems

Carried forward from adversarial review, unsolved, and to be treated as design work in
Stage 3 rather than pretended away:

- **Every deploy migrates every cell.** `fly-replay` routes HTTP but does nothing for an
  open LiveView websocket. A rolling deploy of a large fleet is N lease handoffs plus N
  hydrations, colliding with reconnect storms. Postgres deploys move zero data. This is
  probably the strongest operational objection to the whole architecture.
- **Fencing protects writes, not reads.** A node partitioned from the cluster but not from
  S3 can serve stale-but-plausible reads from a cell it no longer owns. Needs bounded-
  staleness lease checks on the read path — which reintroduces the clock assumptions the
  "no consensus" story claimed to avoid.
- **Background work has no request boundary.** Oban/AshOban jobs run wherever they're
  polled, with no cell affinity. Options — RPC to owner, job acquires the cell (ping-pong),
  or per-cell queues — all have costs. Most real Ash apps are ≥30% background work, so this
  needs a first-class answer.
- **Thundering herd on node loss.** N cells re-hydrating simultaneously. celld's own figures
  are ~4ms warm activation but ~20s restore. Needs compaction SLOs and restore admission
  control. Note Turso's counter-position: "a database is a file rather than a process — no
  cold starts."
- **Lazy migration failure is a single-tenant outage at an unwatched hour**, possibly
  mid-migration given no transaction support. Eager fleet migration on deploy should be
  primary; lazy is the fallback; quarantine state required.

## 5. The demo

Unchanged in shape from rev 1 — one LiveView, four panels, fictional multi-tenant SaaS —
with these corrections.

**Panel D (compliance theatre) leads.** Live hexdump of an encrypted tenant file beside an
unencrypted control with readable names; key revocation; tenant deletion as `rm` beside
Postgres still holding dead tuples; whole-tenant export as a file download.

**Panel B's query must be rewritten without aggregates.** The rev 1 query used an
aggregate-backed sort, which AshSqlite cannot do. Rebuild it on expression calculations
(supported, including sort) and deep multi-level `load`. That is the honest showcase
anyway, because **N+1 immunity is the real win** — four relationship levels over 50k rows
returning in single-digit milliseconds, with the generated SQL shown so it doesn't read as
a cache trick.

**Panel C compares fairly.** Same resources, same query, identical seed, against a properly
indexed AshPostgres shared-schema setup on a realistic network hop. If we need to handicap
Postgres to win, that's a more valuable finding than winning.

**The write panel shows Path A numbers.** Local fsync plus ~1s-RPO async shipping is the
number we can actually ship. If Path B is ever demoed, it must show ~90ms and say why.

## 6. Decision gates

**Proceed past Stage 1 only if:**
- The context repo override works as documented, with no wrapper data layer needed.
- Cross-data-layer relationship loading is fast enough to be idiomatic.
- The no-aggregates / no-transactions constraint is tolerable for the target market, or
  upstreaming aggregates is a project we want.
- Resident-cell density is economic on measured numbers, not estimates.

**Reconsider entirely if:** the transaction gap makes the data-integrity story
unsellable to the compliance market we're targeting, which would be ironic and fatal.

## 7. Prior art

Greenfield in Elixir — nothing occupies this niche. Nearest neighbours: `akoutmos/litestream`
(supervises the binary, single-config, pre-v0.5), Elixir Forum threads on per-customer SQLite
at the raw-Ecto level, and [Distributed SQLite with Elixir](https://silbernagel.dev/posts/distributed-sqlite-with-elixir)
(GenServer-owned SQLite with cross-node replication; closest architectural cousin, not Ash,
not S3).

Validation from the commercial side: **Cloudflare D1** caps at 50,000 databases per account
and explicitly markets per-tenant sharding, with each DB backed by a Durable Object — the
same single-owner shape as our GenServer. **Turso/libSQL** sells per-tenant databases
directly. The architecture is proven; the Elixir/Ash expression of it is not.

## 8. Open questions

1. Is upstreaming aggregates to ash_sqlite a project we want? It is the single highest-value
   contribution available here and would benefit far more people than AshCell.
2. Does the demo need a second node before it is convincing, or does single-node with a
   simulated cold start carry the argument?
