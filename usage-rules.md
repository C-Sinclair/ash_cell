# Rules for working with AshCell

## Understanding AshCell

AshCell gives an Ash application **one SQLite database file per tenant**. A tenant's
data is a separate encrypted file, opened by exactly one Elixir process at a time,
optionally replicated to S3-compatible object storage with ownership enforced by
conditional writes.

The unit is a **cell**: one file, one connection (`pool_size: 1`), one writer. Ash's
tenant is resolved to a *cell key* once, at the edge; everything below that speaks
cell keys. So the cut does not have to be "one cell per customer" — see
[Cutting cells some other way](#cutting-cells-some-other-way).

AshCell requires a **fork of `ash_sqlite`**. Upstream cannot express
database-per-tenant: SQLite has no schemas, so isolation comes entirely from which
file the connection is attached to, and nothing upstream chooses that file.

## Setting up

Add the fleet to the supervision tree. It is a supervisor, not a repo:

```elixir
children = [
  {AshCell,
   repo: MyApp.CellRepo,
   dir: "/data/cells",
   migrator: MyApp.CellMigrations,
   max_resident: 256}
]
```

`:repo` is a **template**, not a started repo. Each cell starts its own anonymous
instance of it. Do NOT also add `MyApp.CellRepo` to the supervision tree, and do not
add it to `config :my_app, ecto_repos:` — it is never started under its own name.

## Defining a cell resource

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

- `strategy :context` is required. `AshCell.Resource` has a verifier that rejects
  `:attribute` and rejects a resource with no multitenancy at all.
- The extension sets `tenant_binder AshCell.Binder` and `transactions? true` in the
  `sqlite` section, and adds a change carrying the tenant into the transaction
  callback. Setting either option yourself wins.

## Calling actions

Pass `tenant:` and nothing else. Do not bind, wrap, or pass a repo:

```elixir
Ash.read!(MyApp.Patient, tenant: "acme")
Ash.count!(MyApp.Patient, tenant: "acme")
MyApp.Patient.create("Ada Lovelace", tenant: "acme")
```

This works from **any process** — a controller, a `Task`, a LiveView callback, an
Oban job on another node. The data layer asks `AshCell.Binder` for a connection once
per statement, from the process about to issue it, so nothing is inherited and
nothing needs wrapping.

**Do not call `AshCell.bind/1` before an Ash call.** It is redundant on an
`AshCell.Resource` resource, and writing it teaches the wrong model — that the
binding is ambient and inheritable, which is the bug it exists to prevent.

## Working outside a resource

Code that touches a cell *without* going through Ash must bind for itself:

```elixir
AshCell.with_tenant("acme", fn ->
  Ecto.Adapters.SQL.query!(MyApp.CellRepo.get_dynamic_repo(), "VACUUM", [])
end)
```

Use `with_tenant/2` for raw Ecto, `AshCell.checkpoint/1`, and benchmarks.

## Transactions

Each action is already transactional. To make several atomic together:

```elixir
AshCell.transaction("acme", fn ->
  {:ok, patient} = MyApp.Patient.create("Ada", tenant: "acme")
  {:ok, _visit} = MyApp.Visit.create(patient.id, tenant: "acme")
end)
```

Returns `{:ok, result}` or `{:error, reason}`. Abort with `AshCell.rollback/1`.
Actions inside join the open transaction rather than opening their own.

**A transaction cannot span two cells.** Separate files, separate connections, and
WAL loses cross-database atomicity even with `ATTACH`. A statement for a different
cell inside an open transaction raises. If two writes must be atomic, they must live
in one cell — design the cell cut around that, do not work around it.

Writes use `BEGIN IMMEDIATE`. This is deliberate: a deferred read-then-write must
upgrade its lock, and SQLite fails an upgrade immediately regardless of
`busy_timeout`.

## What AshSqlite cannot do

Write queries accordingly — these are data-layer limits, not AshCell's:

- **No aggregates.** `count`, `sum`, `first`, `exists` as *Ash aggregates* are
  unsupported. `Ash.count/2` works; a `count :x, :rel` aggregate on a resource does
  not.
- **No lateral joins, no `distinct`, no locks.**
- **Expression calculations work**, including sorting by them. Prefer them.

## Non-tenanted resources

A shared table is a plain `AshSqlite.DataLayer` resource — `AshCell.Resource`
requires a tenant. **Give it its own repo module:**

```elixir
sqlite do
  table "plans"
  repo MyApp.GlobalRepo   # NOT MyApp.CellRepo
  transactions? true
end
```

Ecto keys its dynamic binding as `{repo_module, :dynamic_repo}`. A shared resource
on its own module is immune to cell bindings by construction. One sharing the cells'
repo module inherits whatever the process happens to have bound, and **its rows land
in that tenant's database, silently**. This is the single most damaging mistake
available in an AshCell codebase.

## Cross-data-layer relationships

A relationship between a global Postgres resource and a cell resource supports
`load` only — no SQL-level filtering, sorting, or aggregating across the boundary.
Denormalise the attributes you filter or sort by into the cell at write time.

## Migrations

There is no moment at which the fleet shares a schema. Migrations are versioned per
cell against `PRAGMA user_version` and applied on activation, before the cell serves
anything.

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

- Migrations are **append-only and numbered from 1**. Never renumber or edit a
  shipped migration — cells that already ran it will not run it again.
- Do not use `mix ash.codegen` / generated AshSqlite migrations for cell resources.
- A cell whose migration fails is **quarantined**: it does not start, and its tenant
  gets an error rather than a database in an unknown state.
- Migrate eagerly at deploy time so failures surface while somebody is watching:
  `mix ash_cell.migrate --tenants acme,globex`. Lazy migration on first touch is the
  fallback, not the plan.

## Encryption

```elixir
{AshCell, repo: MyApp.CellRepo, dir: "/data/cells", key_for: &MyApp.Vault.key_for/1}
```

Requires `exqlite` compiled against SQLCipher, which is not the default and **fails
silently** — you get plain SQLite that cannot open an encrypted database:

```bash
export EXQLITE_USE_SYSTEM=1
export EXQLITE_SYSTEM_CFLAGS=-I$(brew --prefix sqlcipher)/include/sqlcipher
export EXQLITE_SYSTEM_LDFLAGS="-L$(brew --prefix sqlcipher)/lib -lsqlcipher"
mix deps.compile exqlite --force
```

Run `mix cipher.check` after any dependency rebuild. It asserts `PRAGMA
cipher_version` is non-empty, and it is the only thing that catches this.

A fleet configured with `key_for` never falls back to an unencrypted file when a key
is missing — the cell refuses to start.

## Replication and ownership

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

Correctness rests on the **conditional write**, not on the lease. Durability writes
are keyed by txid in one namespace every owner shares, so a displaced writer's PUT
is refused and it finds out *before* acknowledging. The lease is an efficiency
measure that stops the fleet fighting over a file.

Fencing protects **writes, not reads**. A partitioned node can serve stale reads
from a cell it no longer owns, bounded by refusing to serve past the lease TTL.

Call `AshCell.drain/0` on shutdown. It seals, quiesces, checkpoints, snapshots and
**releases the lease** for every resident cell — the release is what stops every
successor waiting out the full TTL for every tenant on every deploy.

## Web and background work

**Route the request to the node holding the cell.** A cell is open in one place, so
move the request to the data rather than proxying queries to it:

```elixir
plug AshCell.Plug.OwnerRouting,
  tenant: &MyAppWeb.Tenancy.from_conn/1,
  store: {MyApp.ObjectStore, :config, []}
```

On Fly.io this replies with `fly-replay`. Elsewhere supply a `redirect_to` callback,
or omit it and the local node takes the lease — correct for single-node and dev.

**LiveView** — use the hook, never bind once in `mount/3`:

```elixir
on_mount {AshCell.LiveView, :bind_tenant}
```

A LiveView outlives the cell's repo instance, so a binding taken at mount eventually
points at a dead one. The hook binds per callback and registers the view as a
holder, which is what lets a drain know somebody is still attached.

**Background jobs carry the tenant, they never inherit it.** A binding does not
survive `Task.async`, `Ash.load` fan-out, or an Oban job:

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

Put the tenant id in the job args. It serialises, and it means the same thing on
another node.

## Cutting cells some other way

The cell key is opaque — a registry key, a filename, and an object-store prefix — so
any partitioning you can name in the tenant value works with no code change:

- **per tenant** (the default)
- **per entity** — `"doc:<uuid>"`, a channel, chat session, or agent
- **per tenant per window** — `"acme:2026-08"`, which bounds cell size permanently
- **per workload** — `"acme:billing"`

Supply a resolver rather than mangling tenant values downstream. Two rules:

- **A resolver sees the tenant and deliberately not the query.** The data layer asks
  for a connection once per *statement*, so a query-dependent resolver could route
  two statements of one action to two cells — and a transaction cannot span two
  cells.
- **Never sanitise a key by replacing awkward bytes.** `AshCell.CellKey.encode/1`
  escapes (`~` plus hex) because it must be injective. Mapping `"a:b"` and `"a_b"`
  to one filename puts two cells in one database and crosses the isolation boundary
  with nothing raising.

Anything finer than per-tenant gives up cross-cell transactions and cross-cell
queries, and multiplies the cell count that deploy-migration and thundering-herd
both scale with.

## Reads that must not open a cell

`AshCell.ReadCache` publishes per-cell projections into `:persistent_term`, read
lock-free from any process. It is sound *because* a cell has one writer: writes
bracket themselves with `begin_write/1` and `end_write/2`, and publishing is refused
while a write is in flight. Do not reach for a general-purpose cache here — the
invalidation is what makes this correct, and a shared-database cache cannot have it.

## Operations

```elixir
AshCell.fleet()              # per-cell stats for resident cells
AshCell.resident_tenants()   # who is open right now
AshCell.checkpoint("acme")   # fold the WAL into the main file
AshCell.close("acme")        # close the cell, leave the file
AshCell.delete("acme")       # close it and delete the bytes
AshCell.drain()              # hand every cell over and release its lease
```

**Checkpoint before copying or inspecting a cell file.** In WAL mode a committed row
lives in `<db>-wal` until a checkpoint moves it, so anything reading the file
directly silently misses recent writes.

## Known limits — do not claim otherwise

- **Recovery point is ~1 second, not zero.** Replication ships on an interval.
- **Every deploy migrates every cell**, and `fly-replay` does nothing for a
  websocket that is already established.
- **Thundering herd on node loss is unsolved.** Cold restores need admission control.
- **Durability is whatever your pragmas say.** `exqlite` defaults `synchronous` to
  `:normal`, which in WAL mode means a returned `COMMIT` has not been fsynced.
- **HIPAA does not require physical isolation.** It is a blast-radius reduction and
  an enterprise sales position, not a regulatory advantage.
- **Per-tenant keys are not confidential computing.** The node holds the plaintext
  key in order to serve.

## Testing

The suite needs a running MinIO — `scripts/minio.sh` starts one. Seventeen tests
fail without a reachable object store, deliberately: they test conditional-write
semantics, and a mock would only confirm our own reading of them.

**Cell names in tests must carry wall-clock time.** Use
`AshCell.ObjectStoreCase.unique_cell/1`. `System.unique_integer/1` restarts from
small numbers each VM run while the bucket outlives every run, so a name built from
it alone inherits a previous run's lease and snapshots — and whether a test passes
depends on what ran before it.
