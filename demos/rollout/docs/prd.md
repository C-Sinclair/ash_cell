# Rollout — over-the-air updates on AshCell

A PoC. One cell per release channel, content-addressed blobs in the object store, and
linearizable reads on the pointer that decides what every device installs next.

## Why this demo exists

The three existing demos all have the same load shape in common: the cell is where the
*data* lives, and reads and writes both touch it. An OTA service is not shaped like that,
and that is the point of building it.

An OTA service splits into two halves with opposite characteristics:

- **The pointer graph.** "`prod` is release 42, which needs blobs `a1b2…` and `c3d4…`,
  gated on runtime ≥ 1.4.0, iOS arm64, 10% rolled out." A few KB. Written rarely — a
  promote, a rollout bump, a rollback. Read on every device check-in. Every write is a
  read-modify-write that *must* serialise: two nodes cannot concurrently decide what
  `prod` points at.
- **The payload.** Immutable, content-addressed blobs. Enormous. Wants no database at
  all — the hash is the name, the object store is the whole storage layer, and nothing
  is ever mutated.

That is exactly the split a cell fits: a serialising writer for the decision, content
addressing for the mass. Rollback stops being a data migration and becomes a pointer flip
inside one transaction on one file.

## What this proves

1. **Resolve is a local read.** A device check-in carries its capability vector; the cell
   answers with a manifest and the blob hashes the device lacks. Staged rollout is a
   deterministic hash-bucket on the device id, so there is no write on the read path.
2. **Rollback is a transaction, not a migration.** Flip the pointer; every check-in that
   starts after the commit gets the old release, and the fenced predecessor cannot
   reinstate the new one.
3. **Content-addressed GC is sound because the reference graph has exactly one writer.**
   A blob unreferenced by any release in the cell can be deleted from the bucket. That
   is a *consequence* of single-writer ownership, not a restatement of it, and it is the
   sharpest of the three claims.
4. **Linearizable reads at fan-out are affordable when writes are rare** — and the
   library gains a way to say which trade you are making. See below.

This is also the first demo where the bucket holds something other than cell snapshots.
Blobs are first-class objects sharing the store, which exercises `AshCell.CellKey`
pathing in a way nothing else does.

## The cell cut: a coordination scope

One cell per channel — `myapp/prod`, `myapp/beta`, `myapp/canary`. Not per tenant, not
per record, but per *coordination scope*.

| Demo | Cut | Load shape |
|---|---|---|
| `console` | tenant | read-heavy, isolation pitch |
| `collab_editor` | record | write-contended, one hot writer |
| `shroud` | user | fan-out reads across many cells |
| `rollout` | coordination scope | **near-zero writes, enormous read fan-in on one cell** |

A channel cell is a few hundred KB, which is a cell you can ship whole to every read
replica. The snapshot machinery already built *is* the replication mechanism — no other
demo gets to say that.

## Instant reads: what the levers actually are

The requirement is strict: after a rollback commits, no device may be handed the bad
release. That is linearizability on the pointer, and it is achievable — but the cost has
to be paid somewhere, and this workload is unusual in that it can afford to pay it on the
write.

Two independent levers:

- **Where the read happens** — the owner node only, or any node.
- **Who pays for freshness** — the reader checks before answering, or the writer revokes
  before committing.

The two sensible corners:

| | All traffic to the owner | Read replicas + revoke-before-commit |
|---|---|---|
| Per-read cost | microseconds | microseconds |
| Read latency as the device feels it | one WAN hop to the owner | local, wherever the device is |
| Read capacity | one node | every node |
| Write latency | local commit, instant | must revoke every outstanding lease first |
| **Write availability** | fine | **a rollback blocks if a reader is unreachable** |
| Consistency | linearizable | linearizable |

Note what the trade is *not*: in the single-node design reads are not slow. Each read is
the fastest of any option. What you pay is getting there — every device on earth routes
to one node, so you eat geography and you cap at one machine's read capacity. The read is
fast; the journey is long and the door is narrow.

The cost of the replicated design is the last two rows, and the write-availability row is
the one people miss. Revoke-before-commit means a commit cannot complete until every
reader has acknowledged or its lease has expired, so during a partition a rollback stalls
for the full lease TTL. Read locality was bought with a write path that a *reader* can
block.

Both designs deliver the guarantee. They differ in what breaks and where. The demo ships
both and publishes the stalled-rollback-under-partition number, because that number is
the finding, not the flaw.

### What "instant" can and cannot mean

Stated up front, because this is where a pitch like this usually overclaims:

- **Guaranteed** — any check-in that *starts* after the rollback commits gets the old
  release. That is the linearization point, and it is the one that matters.
- **Undefined** — check-ins in flight at the moment of commit may see either. Unavoidable
  and harmless.
- **Impossible** — a device already downloading the bad bundle. It holds a manifest that
  is stale by construction. OTA rollback means "stop handing it out", never "un-install".

## Measured: the read pool is not the lever, the cache is

`AshCell.Cell` starts every cell with `pool_size: 1`, which serialises every read behind
every other read on the same file. SQLite in WAL mode is MVCC — readers do not block each
other and do not block the writer — so that serialisation looked like a free 10× waiting
to be collected by widening the pool.

It is not. Measured by [`scripts/read_pool_probe.exs`](../../../scripts/read_pool_probe.exs)
— 32 concurrent readers × 200 reads, median of five, WAL, one file:

| | Pointer read (1 row, PK) | Manifest resolve (join + filter, ~12 rows) |
|---|---|---|
| `pool_size: 1` | **17.0 µs** — 59k reads/s | **34.1 µs** — 29k reads/s |
| `pool_size: 2` | 18.1 µs | 37.3 µs |
| `pool_size: 4` | 24.3 µs | 47.0 µs |
| `pool_size: 8` | 20.2 µs | 64.0 µs |
| `pool_size: 16` | 13.6 µs | 49.6 µs |
| `:persistent_term` | **0.04 µs** — 22M reads/s | n/a |

Widening the pool buys nothing on the point read (non-monotonic, inside the noise) and
makes the realistic read materially **worse** — `pool_size: 8` is 1.9× slower than
`pool_size: 1`. Per-query overhead dominates, and extra connections on one file add
contention rather than parallelism.

Two consequences, both load-bearing for this demo:

1. **`pool_size: 1` stays.** No library change, and the existing claim that same-cell
   write contention serialises on the pool is untouched.
2. **The in-process cache is the entire win.** ~400× on the point read, ~850× against the
   manifest resolve. Everything interesting about the read path is above SQLite, not
   inside it.

## The four read strategies

The cache is only *correct* because the owner process is the sole writer: it knows, in
commit order, exactly when the pointer changed. There is no invalidation problem to get
wrong. The cell's authority over writes is what makes an in-memory read path sound rather
than merely fast — the Durable Object pattern in full.

`:persistent_term` is the right store: lock-free, zero-copy reads from any process on the
node, no mailbox to serialise on. Its one drawback is that *writes* trigger a global GC
scan, which is why it is the wrong tool for almost every cache and the right one here.
Writes are deploys.

| Strategy | Where reads happen | Freshness | New failure mode |
|---|---|---|---|
| `:owner` | owner node, straight to SQLite | linearizable | none — the honest default |
| `:cached` | owner node, from `persistent_term` | linearizable | none |
| `:replicated` | any node, local cache invalidated by broadcast | **bounded staleness** | stale reads for the broadcast window |
| `:leased` | any node, holding a read lease | linearizable | writes block on unreachable readers |

`:replicated` is what most OTA services actually want — a 5 ms window on a rollback is not
a real problem — and it must be labelled as not linearizable so that choosing it is a
decision rather than an accident.

`:leased` is not new machinery. It is `AshCell.Ownership` and `AshCell.Lease` pointed at
readers instead of writers, which is both a reason to believe it is buildable and a reason
this demo is the right place to build it. It is also the first honest answer in this repo
to *"fencing protects writes, not reads"*: not a general fix, but for a value read
constantly and written rarely, revoke-before-commit closes it.

### Cell-level or resource-level?

Both, at different layers — and the distinction matters because a cell is a whole SQLite
database with many resources in it.

**Replication topology is irreducibly per-cell.** You cannot ship half a SQLite file. If a
cell is replicated to a node at all, that node has every table in it. So `:replicated` and
`:leased` describe where the *bytes* are, and that is a property of the cell.

**Read admission can be per-resource.** Leasing is not about which bytes are present, it
is about whether you are permitted to trust the local copy. On the same replica of the
same file, one resource can demand a valid read lease while another reads the local copy
immediately. Same bytes, different admission rule.

The seam already exists in the fork. `bind_tenant/3` (`ash_sqlite/lib/data_layer.ex:2302`)
receives the resource, and its call sites distinguish reads (`:609`, `:624`) from writes
(`:1409`, `:1561`, `:1621`) and transactions (`:2252`). Extending
`AshSqlite.TenantBinder.bind/2` to carry the resource and the usage is a narrow,
upstreamable change with exactly one implementor (`AshCell.Binder`). **Not to be made
until this demo needs it** — per repo convention, the demo forces the change rather than
the change anticipating the demo.

The coupling that cannot be escaped: **the strictest resource in a cell sets the write
cost for the whole cell.** A commit is per-file, so if any resource in the cell is
`:leased`, every write to that cell pays the revoke round trip.

Which yields a design rule, now derived rather than asserted:

> Put data wanting different consistency in different cells.

## Where install events go

Not in the pointer cell. They have no read-your-write requirement, they are append-only,
and at check-in volume they would invalidate the read cache constantly — destroying the
`persistent_term` path that the previous section shows is the entire win.

So install telemetry batches to its own cell, where staleness costs nothing. The demo
measures both, *and* measures the naive co-located version, because "what happens when you
put the observation stream in the decision cell" is a more instructive number than the
happy path. The write-ceiling measurement belongs here as the counterexample.

## Data model

**Global (Postgres).** Apps, channels, and the channel → cell mapping. Devices, if the
demo needs a fleet view.

**Per channel cell.**

| Resource | Role |
|---|---|
| `Release` | a version, its notes, its state (`draft`, `live`, `superseded`, `rolled_back`) |
| `Artifact` | one blob reference: hash, kind, size, and its compatibility bounds |
| `Pointer` | the single row that says what this channel currently serves, plus rollout percentage and cohort rule |
| `Promotion` | the append-only log of pointer changes — what made this decision, and when |

Compatibility matching is filters plus expression calculations. **AshSqlite has no
aggregates**, so nothing in the resolve path may depend on one.

## The resolve path

`POST /v1/updates/check` carrying `{channel, platform, arch, runtime_version,
current_release}`. The response is the manifest and the blob hashes the device lacks, with
presigned URLs. Rollout gating is `hash(device_id <> release_id) % 100 < percentage`, so
the same device gets a stable answer across retries with no state written.

## Non-goals

- **Not a CDN.** Blob delivery is presigned URLs. Edge caching is out of scope.
- **No delta or patch generation.** Whole blobs.
- **No signing or attestation.** A real fleet needs both; they are orthogonal to the cell
  argument and would only pad the demo.
- **No fleet-wide analytics.** "What version is everyone on" crosses channels and
  re-comingles — the same limit as cross-tenant analytics in `console`. Named, not built.
- Not production auth, not device enrolment, not rate limiting.

## Where it stops

- **One hot cell per channel is a real ceiling.** Measured, published, not dodged.
- **Fencing protects the pointer write, not the read.** Under `:replicated` a partitioned
  node serves a stale pointer, so a device can be handed a release that was rolled back
  moments ago. This demo is where that open problem acquires a user-visible consequence,
  which makes it a better demonstration of the hazard than the abstract note in
  `CLAUDE.md`.
- **`:leased` trades write availability for read locality.** A partition stalls rollbacks
  for the lease TTL. Acceptable here; not universally.

## Measurements this demo must produce

1. Resolve latency (p50/p99) for each of the four strategies, against a Postgres
   equivalent running the same query through Ash — the fair-comparison discipline from
   `console`, where the first benchmark was wrong precisely because it was not fair.
2. Rollback visibility: time from commit to the first check-in that cannot see the bad
   release, per strategy. Zero for `:owner` and `:cached`, bounded and *stated* for
   `:replicated`, zero for `:leased`.
3. Rollback latency under partition for `:leased`, with one reader node unreachable.
4. Write ceiling on the pointer cell, with and without install events co-located.
