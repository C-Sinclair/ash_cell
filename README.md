# AshCell

Database-per-tenant SQLite for [Ash Framework](https://hexdocs.pm/ash). Each tenant
is a **cell**: one encrypted SQLite file, owned by one Elixir process at a time,
replicated to S3-compatible object storage.

```elixir
# No binding, no connection juggling — just a tenant.
MyApp.Patient |> Ash.read!(tenant: "acme")
MyApp.Patient.create("Ada Lovelace", tenant: "acme")
```

> **Status: experimental.** Working end to end with a test suite and five demos, all
> of them in CI — but the API is not stable and it has not been run in production. See
> [What's proven, and what isn't](#whats-proven-and-what-isnt).

## Why

**Blast-radius isolation.** A tenant's data is a separate encrypted file, not a
`WHERE` clause. An authorization bug cannot leak across tenants because there is no
shared table to leak *from*. Deletion, export, and per-tenant restore become file
operations — `rm` really is the deletion story, with no vacuum and no tombstones.

**N+1 immunity.** Compute sits with storage, so deep relationship loads cost almost
nothing. Measured on the demo dataset (60 patients, 180 encounters, 720 observations
per clinic; median of five, both sides warmed):

| | Deep three-level load |
|---|---|
| **AshCell** (Ash + SQLite) | **~3.0 ms** |
| Postgres (Ash + Postgres) | ~9.1 ms |
| Postgres (raw SQL, no framework) | ~2.8 ms |

The third row is the point: going through the whole Ash framework lands level with
hand-written SQL, because the framework's cost stops being hidden behind a network
round trip.

### What this is *not*

- **HIPAA does not require physical isolation.** The Security Rule is access
  controls, audit, and encryption; auditors accept row-level tenancy routinely.
  Physical isolation is a real blast-radius reduction and a strong enterprise sales
  position. It is not a regulatory advantage.
- **Per-tenant keys are not confidential computing.** The node holds the plaintext
  key in order to serve. Revoking a key stops future hydrations; it does not eject a
  resident cell.
- **Cross-tenant analytics re-comingles the data** that the isolation story
  disclaims. It needs its own controls and its own deletion story.

## Requirements

AshCell needs a **forked `ash_sqlite`**. This is not incidental — upstream cannot
express database-per-tenant, for two reasons.

**1. Multitenancy.** SQLite has no schemas, so Ash's `strategy :context` cannot be a
query prefix the way it is in AshPostgres. The generated SQL is identical for every
tenant, and isolation comes entirely from *which database file the connection is
attached to*. Nothing in upstream chooses that file, so the choice fell to whoever
last called `Ecto.Repo.put_dynamic_repo/1` on the calling process — which means
every caller has to bind, at every entry point, including the ones that cannot:
`Ash.count/2` never enters `Ash.Actions.Read`, and an atomic update never
materialises a changeset to hook.

The fork adds a `tenant_binder` option. The data layer asks it which connection to
use, once per statement, from the process about to issue it — so reads, aggregates,
atomic updates and bulk writes all route correctly with no caller ceremony.

**2. Transactions.** Upstream reports `can?(:transact) → false`, so no Ash action on
SQLite is transactional: a `create` whose `after_action` hook fails leaves the row
behind. That default is about contention, not capability — SQLite is fully ACID, but
it allows one writer at a time and a contended write fails rather than queueing.

A cell is one file behind one connection with `pool_size: 1`, which is precisely the
topology that objection doesn't apply to: there is no second writer to contend with.
The fork adds a `transactions?` option (off by default, so upstream behaviour is
unchanged) and the callbacks it needs, opening writes as `BEGIN IMMEDIATE`.

Both changes are written to be upstreamable, and the intent is to retire the fork.
Until then AshCell depends on it by git.

You also need **SQLCipher** if you want encrypted cells (see [Encryption](#encryption)).

## Installation

**Not on Hex, and not able to be** until the fork's changes land upstream — Hex
refuses a package with a git dependency. Install from git:

```elixir
def deps do
  [
    {:ash_cell, github: "C-Sinclair/ash_cell"},
    # Required: see Requirements above. `override: true` because ash_cell's own
    # dependency tree would otherwise pull upstream ash_sqlite.
    {:ash_sqlite, github: "C-Sinclair/ash_sqlite", override: true}
  ]
end
```

## Setup

Add the fleet to your supervision tree:

```elixir
children = [
  {AshCell,
   repo: MyApp.CellRepo,
   dir: "/data/cells",
   migrator: MyApp.CellMigrations,
   max_resident: 256}
]
```

| Option | Default | Meaning |
|---|---|---|
| `:repo` | *required* | A repo module used as a **template**. Each cell starts its own anonymous instance of it (`start_link(name: nil, database: path)`), so the module is never started under its own name. |
| `:dir` | *required* | Directory holding the cell files. |
| `:migrator` | `nil` | Module defining per-cell migrations. See [Migrations](#migrations). |
| `:max_resident` | `256` | Residency bound. Once reached, the least-recently-used cell is closed. Closing drops a connection; the data is a file and stays put. |
| `:key_for` | `nil` | `fn tenant -> key end`. Supplying it turns on encryption. |
| `:store` | `nil` | An `AshCell.ObjectStore` struct. Supplying it turns on replication and lease-based ownership. |
| `:snapshot` | on with a store | When a cell ships itself. A keyword list (`wal_bytes`, `max_age_ms`, `interval_ms`) or `false` to ship only on drain. See [Replication and ownership](#replication-and-ownership). |
| `:owner` | `node()` | This node's identity in leases. |

The repo is an ordinary `AshSqlite.Repo`:

```elixir
defmodule MyApp.CellRepo do
  use AshSqlite.Repo, otp_app: :my_app

  def installed_extensions, do: []
end
```

## Defining a resource

Add the `AshCell.Resource` extension and declare `strategy :context`:

```elixir
defmodule MyApp.Patient do
  use Ash.Resource,
    domain: MyApp.Clinical,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table "patients"
    repo MyApp.CellRepo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:name]]
  end
end
```

The extension does three things: points the resource's `tenant_binder` at
`AshCell.Binder`, sets `transactions? true`, and adds a change that carries the
tenant to the one callback which cannot read it off a changeset. Set
`tenant_binder` or `transactions?` yourself and your value wins.

## Usage

Ordinary Ash calls, from anywhere — a controller, a `Task`, a LiveView, a job on
another node. Nothing is inherited and nothing needs wrapping:

```elixir
Ash.read!(MyApp.Patient, tenant: "acme")
Ash.count!(MyApp.Patient, tenant: "acme")
MyApp.Patient.create("Ada Lovelace", tenant: "acme")
```

### Transactions

Each action is transactional on its own. To make several atomic together:

```elixir
AshCell.transaction("acme", fn ->
  {:ok, patient} = MyApp.Patient.create("Ada", tenant: "acme")
  {:ok, _visit} = MyApp.Visit.create(patient.id, tenant: "acme")
end)
```

Returns `{:ok, result}` or `{:error, reason}`; call `AshCell.rollback/1` to abort.
Actions inside join the open transaction rather than opening their own.

**A transaction cannot span two cells.** They are separate files on separate
connections, and SQLite loses cross-database atomicity in WAL mode even with
`ATTACH` — so a statement for another tenant inside an open transaction raises,
rather than committing independently and surviving a rollback. If two things must be
atomic, put them in one cell.

### Resources that are not cells

A shared table is a plain `AshSqlite.DataLayer` resource — `AshCell.Resource`
requires a tenant. Transactions still work via the `sqlite` section directly:

```elixir
sqlite do
  table "plans"
  repo MyApp.GlobalRepo   # <- its own repo module, not MyApp.CellRepo
  transactions? true
end
```

**Give it its own repo module.** Ecto keys the dynamic binding as
`{repo_module, :dynamic_repo}`, so binding a cell affects one module only. A shared
resource on its own repo module is immune to cell bindings by construction. One
sharing the cells' repo module inherits whatever the process happens to have bound,
and its rows land in that tenant's database — silently.

### Working outside a resource

Anything that talks to a cell without going through Ash binds for itself:

```elixir
AshCell.with_tenant("acme", fn ->
  Ecto.Adapters.SQL.query!(MyApp.CellRepo.get_dynamic_repo(), "VACUUM", [])
end)
```

## Migrations

There is no moment at which the whole fleet shares a schema — that is the price of a
database per tenant. Migrations are versioned per cell against `PRAGMA user_version`
and applied on activation, before the cell serves anything.

```elixir
defmodule MyApp.CellMigrations do
  use AshCell.Migrator

  migration 1, """
  CREATE TABLE patients (id TEXT PRIMARY KEY, name TEXT NOT NULL)
  """

  migration 2, fn repo_pid ->
    Ecto.Adapters.SQL.query!(repo_pid, "ALTER TABLE patients ADD COLUMN mrn TEXT", [])
  end
end
```

A cell whose migration fails does not start: it is **quarantined** and its tenant
gets an error rather than a database in an unknown state.

Migrate the fleet eagerly at deploy time, so failures surface while somebody is
watching. Lazy migration on first touch is the fallback, not the primary path:

```bash
mix ash_cell.migrate --tenants acme,globex
```

## Encryption

Supply `:key_for` and each cell is opened with that tenant's own key:

```elixir
{AshCell, repo: MyApp.CellRepo, dir: "/data/cells", key_for: &MyApp.Vault.key_for/1}
```

Requires `exqlite` compiled against SQLCipher, which is not the default and **fails
silently** — you get plain SQLite that cannot open an encrypted database:

```bash
brew install sqlcipher
export EXQLITE_USE_SYSTEM=1
export EXQLITE_SYSTEM_CFLAGS=-I$(brew --prefix sqlcipher)/include/sqlcipher
export EXQLITE_SYSTEM_LDFLAGS="-L$(brew --prefix sqlcipher)/lib -lsqlcipher"
mix deps.compile exqlite --force
```

Then `mix cipher.check` asserts `PRAGMA cipher_version` is non-empty. Run it after
any dependency rebuild — the assertion is the only thing that catches this.

A fleet configured with `key_for` never falls back to an unencrypted file when a key
is missing; the cell refuses to start. Destroying a key shreds exactly one tenant.

## Replication and ownership

Supply a `:store` and cells replicate to object storage, with ownership enforced by
conditional writes:

```elixir
store =
  AshCell.ObjectStore.new(
    endpoint: "https://s3.amazonaws.com",
    bucket: "my-cells",
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
  )

{AshCell, repo: MyApp.CellRepo, dir: "/data/cells", store: store}
```

Correctness rests on the conditional write, not on the lease: a fenced writer's
conditional PUT is refused, so it cannot persist even if it still believes it holds
the cell. The lease is an efficiency measure that stops the fleet fighting over the
same file.

On shutdown each resident cell is sealed, quiesced, checkpointed, snapshotted, and
its **lease released** before closing. That release is what stops every successor
waiting out the full TTL for every tenant on every deploy.

### When a cell ships

Shipping only on drain would make a clean shutdown safe and `kill -9` lose *everything
written since the cell activated* — not a second of writes, the whole session. So a
cell ships on a schedule, on whichever of two triggers fires first:

| Option | Default | Trigger |
|---|---|---|
| `wal_bytes` | 4 MiB | The `-wal` sidecar has grown past this. One `File.stat`, no SQLite involvement. |
| `max_age_ms` | 60 s | There is *anything* unshipped and it has been that long. Size alone would leave the low-traffic tenant — whose single write matters most — unshipped indefinitely. |
| `interval_ms` | 5 s | How often a cell *asks*, not how often it ships. |

A cell with an empty WAL never ships, so a dormant per-entity cell costs nothing. Each
cell takes a random offset into its first interval and re-jitters every tick, because
a fleet that asked on the same tick would answer together — the whole fleet's bytes
leaving at once, which is the thundering herd re-created on a timer. Shipping happens
off the cell process, so a whole-file PUT does not block that cell's queries.

**A refused shipment stops the cell serving.** `{:error, :precondition_failed}` on a
durability write is the only local signal that a successor has claimed the cell and
written past this node's high-water mark. Being displaced is safe until then — the
conditional write is what makes it safe — and unsafe from then on: every further write
is unshippable and every read answers from a database whose real owner has moved on. So
the cell key is quarantined, the process force-closed, and the lease dropped. Recovery
is explicit and ordered: re-claim, restore, release
([ADR-10](docs/decisions/ADR-10-fail-closed-on-a-refused-shipment.md)).

### Durability on power loss

Two failures get conflated and they have different fixes at very different prices.

**The node reboots and the volume survives.** SQLite replays the WAL. What is lost is
whatever had not reached stable storage — and that is more than the last transaction.
Cells run `synchronous: :normal`, which in WAL mode does not fsync at commit at all; it
fsyncs at checkpoint. So the window is the whole WAL since the last checkpoint, bounded
by `wal_autocheckpoint` at roughly 4 MiB. A fleet with a `:store` narrows this by
accident rather than by design — `AshCell.Replicator` checkpoints before it ships, so
`max_age_ms` also bounds the fsync interval. **A fleet with no store gets none of that**
and does not checkpoint until it drains.

**The host or the volume is gone.** Local disk is no help, so the loss is back to the
last shipment: the table above, `max_age_ms` or `wal_bytes`, whichever fires first.

Only the second costs object-store traffic. The first is a local fsync and costs no
network at all.

#### Choosing a `synchronous` level

`synchronous` is a per-connection pragma, so it is per cell. AshCell does not set it,
which means the repo's own application config reaches it — Ecto merges that config
underneath the options AshCell passes:

```elixir
config :my_app, MyApp.CellRepo, synchronous: :full
```

`journal_mode` is *not* configurable this way. Cells pin `:wal` above config, because
replication ships the `-wal` sidecar and `synchronous: :normal` outside WAL risks a
corrupt database rather than a bounded loss.

| Level | A returned `COMMIT` is | Costs | Reasonable when |
|---|---|---|---|
| `:off` | not synced, and the database can be **corrupted** by an OS crash, not merely truncated | nothing | Never for a cell you intend to keep. A disposable rebuild-from-source cell only. |
| `:normal` *(current default, by omission)* | durable against process death, **not** against power loss or a kernel panic | nothing | The loss window is acceptable and bounded by shipping — caches, projections, anything reconstructible. |
| `:full` | fsynced before it returns | one fsync per commit, local only | An acknowledgement is a promise: ledgers, audit logs, anything whose loss is not stale data but state that never happened. |
| `:extra` | fsynced, plus the directory entry synced | a second fsync per commit | Rarely worth it over `:full`; it closes a window on the file's *creation*, not its contents. |

Two things make `:full` cheaper than it looks, and `scripts/write_durability_probe.exs`
measures both. `pool_size: 1` already serialises a cell's writers, and an honest fsync
costs the same whatever it is flushing — so batching several writes into one
`AshCell.transaction/2` pays it once rather than once each. Measured on macOS, a
genuinely-synced commit costs ~4.3 ms at any batch size, which is 4375 µs per row
one-at-a-time and **52 µs per row in batches of 100**. Durability is a batching
question more than a throughput one.

Two caveats, both load-bearing:

- **On macOS, `:full` is not durability.** Plain `fsync` does not flush the drive's
  write cache; that needs `F_FULLFSYNC`. So a local dev machine set to `:full` proves
  nothing about a production Linux host, and vice versa.
- **No test in this repo can tell you whether the level you chose works.** Killing a
  process leaves the page cache intact, so every test passes under every level. The gap
  is only observable across a machine boundary — a VM whose power is cut, or
  `dm-log-writes` replaying the block stream to an arbitrary prefix.
  [ADR-20](docs/decisions/ADR-20-choose-a-durability-level.md) is open and owns this;
  the fleet default is `:normal` by omission rather than by decision.

## Reads and writes

A cell is open on one node at a time, so *where* a statement runs is part of the
design rather than an operational detail. Three separate mechanisms cover it, because
each buys something different at a different price.

### Writes go to the node that owns the cell

A request that lands on the wrong node has three options: proxy every query across the
network — throwing away the colocation that makes this worth having — steal the lease,
thrashing a handover per request, or send the *request* to the data. Only the third
keeps the property the design rests on:

```elixir
plug AshCell.Plug.OwnerRouting,
  tenant: &MyAppWeb.Tenancy.from_conn/1,
  store: {MyApp.ObjectStore, :config, []}
```

On Fly.io this answers `fly-replay` and the platform re-issues the request against the
owning instance — no proxy, no extra hop. Elsewhere pass
`transport: {:redirect, fun}`, or `transport: :none` and the request is served
locally with this node taking the lease, which is correct for single-node deployments
and for development.

The websocket upgrade is an ordinary HTTP request, so it routes the same way. That is
what stops a reconnecting client discovering ownership by trial and error while
somebody watches a spinner. What it deliberately does *not* do is wait for ownership
to settle: an unclaimed lease is taken locally and served, because blocking a user on
a distributed handover costs more than the handover is worth.

### Reads are bounded, not fenced

The conditional write fences writes — a displaced owner's durability write is refused
before it has acknowledged anything. **Reads get no such moment.** A node partitioned
from its peers but still reachable by clients keeps answering from a database another
node has since taken over and moved on from. Nothing fails; the answers are simply
stale, and plausible.

`AshCell.Ownership` is the read-side counterpart, and it offers three levels rather
than one default, because there is no honest single answer:

| Mode | Guarantee | Cost |
|---|---|---|
| `:none` | none | nothing, and no clock assumption at all |
| `:bounded` (default) | a read is never more than the lease TTL behind ownership | trusting the TTL |
| `{:strict, store}` | no staleness window | one round trip to the object store, per read |

```elixir
AshCell.Ownership.with_ownership(ownership, :bounded, fn ->
  Ash.read!(MyApp.Patient, tenant: "acme")
end)
```

The elapsed-time measurement is monotonic, so an NTP step or a VM migration cannot
silently widen the window. **This is the one place in the design where clock skew
matters** — everything else is safe under arbitrary drift because it rests on
conditional writes, and bounded staleness cannot be, since the bound *is* a duration.

`:strict` throws away the entire performance argument for this architecture. Reach for
it on a specific read that genuinely needs it, never as a global default.

This is a mechanism to call, not an ambient check: nothing in the library applies it to
your reads for you. The backstop below it is coarser — a cell that discovers it has been
fenced, by having a shipment refused, is quarantined and closed — but it only fires when
this node next tries to ship.

### Hot reads do not have to open the cell

A cell's reads serialise on its one connection, and there is no widening the pool out
of it: `scripts/read_pool_probe.exs` measures a realistic filtered join getting
*worse* as the pool grows, because per-query overhead dominates and extra connections
on one file add contention rather than parallelism ([ADR-13](docs/decisions/ADR-13-pool-size-one-and-cache.md)).
So the read path is improved *above* SQLite. Measured on that probe, same file:

| | Per read | Throughput |
|---|---|---|
| pointer read, `pool_size: 1` | 17.0 µs | 59k reads/s |
| pointer read, `:persistent_term` | 0.04 µs | 22M reads/s |

`AshCell.ReadCache` holds per-cell projections in `:persistent_term` — lock-free,
zero-copy, no mailbox to serialise on:

```elixir
AshCell.ReadCache.read(channel, :manifest, fn -> build_manifest(channel) end)
```

A cache in front of a shared database is a correctness problem, because you cannot
know when somebody else wrote. A cell has exactly one writer and this node is it, so
the invalidation is not a guess: `AshCell.Binder` brackets every write, erasing the
cell's entries and bumping an epoch before the statement and again *after* the commit,
and refuses to publish while a write is open. Readers may repopulate, because
publishing is a compare-and-set on that epoch. Writers are monitored, so a crash
mid-write cannot leave a stale entry publishable forever.

Writes that bypass the data layer — raw Ecto under `with_tenant/2`, a `checkpoint/1`,
a restore — must call `AshCell.ReadCache.invalidate/1` themselves. This is the same
boundary `AshCell.Binder` has, for the same reason.

It is a **single node's** cache. A four-value `read_strategy` enum
(`:owner`, `:cached`, `:replicated`, `:leased`) was designed and then cut: `:owner`
and `:cached` are what the cache already gives you without a declaration, and
`:replicated` and `:leased` remain designs rather than code. Nothing here caches
across nodes.

## LiveView and background work

**LiveView** — bind per callback, never once in `mount/3`. A LiveView outlives the
cell's repo instance, so a binding taken at mount eventually points at a dead one:

```elixir
on_mount {AshCell.LiveView, :bind_tenant}
```

**Background jobs** carry the tenant rather than inheriting it. A tenant id
serialises into job args and means the same thing on another node:

```elixir
defmodule MyApp.RecalculateRisk do
  use Oban.Worker, queue: :default
  use AshCell.Job

  @impl AshCell.Job
  def perform_for_tenant(tenant, %Oban.Job{args: _args}) do
    MyApp.Patient |> Ash.read!(tenant: tenant)
  end
end
```

## Operations

```elixir
AshCell.fleet()              # per-cell stats for resident cells
AshCell.resident_cells()     # who is open right now
AshCell.path_for("acme")     # the file backing a cell
AshCell.checkpoint("acme")   # fold the WAL into the main file
AshCell.close("acme")        # close the cell, leave the file
AshCell.delete("acme")       # close it and delete the bytes
AshCell.drain()              # hand every cell over and release its lease
```

`checkpoint/1` matters more than it looks: in WAL mode a committed row lives in
`<db>-wal` until a checkpoint moves it, so anything that copies or inspects the file
must checkpoint first or silently miss recent writes.

## What's proven, and what isn't

Proven by the test suite, against real files and a real MinIO rather than mocks:

| | How |
|---|---|
| Ash routes queries to a per-tenant database | `test/probe_test.exs` |
| Isolation is physical, not a filter | each file read directly, bypassing Ash |
| Cells are encrypted at rest | `sqlite3` reports "file is not a database" |
| Exactly one writer wins a contested cell | 12 concurrent claimants, 1 winner |
| A fenced writer cannot persist | conditional PUT refused |
| A destroyed database restores | file deleted, 960 rows restored from the bucket |
| Revoking a key shreds one tenant only | file intact, zero rows readable |
| A drained node hands over immediately | successor claims without waiting the TTL |
| Multi-step actions roll back | `test/transaction_test.exs` |
| A cell taken mid-transaction does not half-apply | force-close between two writes |
| Compaction stays safe under concurrent writers | `demos/collab_editor` — 15 appends racing 4 compactions |
| A cached projection is never stale or published mid-write | `test/read_cache_test.exs`, plus an ordinary Ash write invalidating it |
| An expired lease refuses to serve reads | `test/ownership_test.exs`, on the monotonic clock |
| A refused push is refused, not reconciled | `demos/vcs/scripts/e2e.sh`, real Rust binary against a listening server |
| Two people typing in one paragraph lose nothing | `demos/collab_editor/test/browser/convergence.mjs`, in two real browsers |

Known limits, stated because they are real:

- **Recovery point is ~1 second, not zero.** Replication ships on an interval.
- **No aggregates.** AshSqlite doesn't support them. Expression calculations,
  including sort, do work.
- **Cross-data-layer relationships load only.** A global Postgres table related to a
  cell can be loaded and stitched in memory, not filtered or sorted in SQL.
  Denormalise what you filter on into the cell at write time.
- **Fencing protects writes, not reads.** A partitioned node can serve stale reads
  from a cell it no longer owns, bounded by refusing to serve past the lease TTL.
  This is the one place clock skew matters.
- **Deploys still drop websockets.** Draining makes reconnection fast, but
  `fly-replay` does nothing for a socket already established.
- **Thundering herd on node loss** is unsolved; cold restores need admission control.
- **The read cache is one node's.** Cross-node caching (`:replicated`, `:leased`) is
  designed and not built.
- **Read fencing is a call you make.** `AshCell.Ownership` is not applied to your reads
  automatically, and `:bounded` bounds staleness rather than removing it.
- **Fan-out reads fall off a cliff, not a slope.** `max_resident` below a page's
  working set makes every read evict a cell the next read wants — measured at 8.9× in
  `demos/shroud`.
- **Durability is whatever your pragmas say.** `exqlite` defaults `synchronous` to
  `:normal`, which in WAL mode means a returned `COMMIT` has not been fsynced.

## Demos

Runnable Phoenix applications under [`demos/`](demos), each with a README arguing what it
proves *and where it stops*. They are how the library's claims get checked against something
that has to work rather than something that has to pass. All five run in CI
(`.github/workflows/ci.yml`), so a change to the library that breaks one fails there rather
than the next time somebody opens it.

They are organised by **where the cell is cut**, because that is the point: one cell per
tenant is the default, not the only option
([ADR-19](docs/decisions/ADR-19-the-cell-cut-is-a-choice.md)).

- **One cell per tenant** — [`console`](demos/console). A multi-clinic healthcare SaaS, and
  the core pitch: isolation you can check by reading the bytes off the disk, encryption at
  rest, single-writer ownership, durability to the object store, and the deploy drain. Its
  speed panel runs the same query against a properly indexed Postgres and against raw SQL, so
  the comparison is allowed to lose.
- **One cell per document** — [`collab_editor`](demos/collab_editor). A Lexical + Yjs
  collaborative editor. The CRDT is what makes concurrent typing correct, and the demo says
  so; what the cell provides is a safe home for the update log, because merging it into a
  snapshot and truncating it is a read-modify-write that a CRDT cannot make safe. Checked in
  two real browsers, not just in Elixir.
- **One cell per user** — [`shroud`](demos/shroud). A profile app whose server cannot read
  most of what it stores: the key is derived in the browser from a passkey, and deleting an
  account means destroying key material rather than data. It is also where the fan-out cost
  got measured — 200 cells for one feed page in 16.6 ms, and 8.9× slower when `max_resident`
  is smaller than the page's working set.
- **One cell per release channel** — [`rollout`](demos/rollout). Over-the-air updates: a
  pointer written twice a week and read by every device on every check-in. The read/write
  ratio at the opposite extreme from the editor, and where the read cache does the work —
  roughly 0.34 µs a resolve, visualised live at up to 6,000 real check-ins a second.
- **One cell per repository** — [`vcs`](demos/vcs). A small version control system with a Rust
  CLI and an Ash server. The closest of the demos to what a durable object is for: objects and
  the ref move in one transaction inside one cell, so Git's `main.lock` and its optimistic
  retry are not needed, and the losing push is refused rather than reconciled.

## Documentation

- [Design spec, staging plan, and verified constraints](docs/spec.md)
- [Architecture decisions](docs/decisions/README.md) — one ADR per decision, including the
  five that exist because something believed true was measured false
- [Design docs](docs/design) — written before the work, stating what each piece proves,
  its non-goals, and where it stops
- [Deterministic simulation testing](docs/dst.md)
- [What the demos prove](demos/README.md)
- [Changelog](CHANGELOG.md)

### For coding agents

[`usage-rules.md`](usage-rules.md) is written for LLM coding agents rather than
people. It leads with the mistakes rather than the API, because most of what goes
wrong here is silent — a shared resource sharing the cells' repo module writes its
rows into whichever tenant happens to be bound, and nothing raises.

If your project uses [`usage_rules`](https://hex.pm/packages/usage_rules), it will
be picked up automatically. Otherwise, point your agent at it directly.

## Contributing

Bug reports, questions and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for how to get a working checkout, which is not
quite `mix deps.get && mix test`: the suite needs a running MinIO, and the
encryption paths need an `exqlite` built against SQLCipher.

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).

## License

MIT. See [LICENSE](LICENSE).
