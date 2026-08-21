# AshCell

Database-per-tenant SQLite for [Ash Framework](https://hexdocs.pm/ash). Each tenant
is a **cell**: one encrypted SQLite file, owned by one Elixir process at a time,
replicated to S3-compatible object storage.

```elixir
# No binding, no connection juggling — just a tenant.
MyApp.Patient |> Ash.read!(tenant: "acme")
MyApp.Patient.create("Ada Lovelace", tenant: "acme")
```

> **Status: experimental.** Working end to end with a test suite and two demos, but
> the API is not stable and it has not been run in production. See
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

## Web and background work

**Route requests to the owning node** — a cell is only open in one place, so send the
request to the data rather than proxying queries to it:

```elixir
plug AshCell.Plug.OwnerRouting,
  tenant: &MyAppWeb.Tenancy.from_conn/1,
  store: {MyApp.ObjectStore, :config, []}
```

On Fly.io this replies with `fly-replay`. Elsewhere, supply a `redirect_to`
callback, or omit it and the local node takes the lease — correct for single-node
and development.

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
AshCell.resident_tenants()   # who is open right now
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
- **Durability is whatever your pragmas say.** `exqlite` defaults `synchronous` to
  `:normal`, which in WAL mode means a returned `COMMIT` has not been fsynced.

## Demos

Runnable Phoenix applications under [`demos/`](demos), each with a README arguing what it
proves *and where it stops*. They are how the library's claims get checked against something
that has to work rather than something that has to pass.

### [`demos/console`](demos/console) — one cell per **tenant**

A multi-clinic healthcare SaaS: physical isolation, encryption at rest, single-writer
ownership, object-store durability, N+1 immunity, and the deploy drain — each shown from
outside the application's own claims (raw bytes off the disk, the `sqlite3` CLI's opinion of
a cell file, objects fetched back out of the store). The speed panel runs the same Ash query
against a properly indexed Postgres and against raw SQL, so the comparison can lose.

### [`demos/collab_editor`](demos/collab_editor) — one cell per **document**

A collaborative rich text editor, [Lexical](https://lexical.dev) + [Yjs](https://yjs.dev) in
the browser, one cell per document on the server. It exists to answer a question the console
demo cannot: **is the cell boundary a choice, or is it just "customer" with extra steps?**

How it works:

1. A document id is the tenant. `CollabEditor.CellKey` resolves it to the cell `doc:<uuid>`,
   which lands on disk as `doc~3A<uuid>.db` — the `:` is escaped, and the encoding is
   reversible, so two keys can never share a file.
2. A keystroke produces a Yjs update. The browser pushes it over the LiveView channel; the
   server stores it in that document's `updates` table with a monotonic `seq`, then broadcasts
   it to the other clients on the document.
3. Cursors and names travel the same channel and are **stored nowhere** — ephemeral state is
   not worth the cell's single connection.
4. `Editing.compact/1` merges the log into a snapshot with
   [`y_ex`](https://hex.pm/packages/y_ex) (a Rust NIF over `yrs`) and truncates what it
   merged, all in one transaction on the cell.

**Why this is a good argument for cells, stated narrowly.** Yjs is what makes concurrent
editing correct — updates commute, so two people typing inside the same word converge
character by character and nobody loses a keystroke. That would be true on Postgres too, and
the demo says so. What a CRDT does *not* give you is a safe place to keep the log:

> Compaction is `read the whole log; merge; write the snapshot; delete what was merged`. Two
> nodes doing that concurrently can each merge a log the other is truncating, and an update
> landing between one node's read and its delete is **gone** — a corruption the CRDT cannot
> repair, because the update is no longer anywhere. On shared storage this needs a lock, a
> lease, or a designated compactor.

A cell is all three by construction: one connection per document (`pool_size: 1`), a write
lock taken up front (`BEGIN IMMEDIATE`), one node holding the document (the lease), and one
transaction, so a cell taken mid-compaction aborts rather than leaving a truncated log with no
snapshot.

**How that is proven.** 28 Elixir tests, including 15 concurrent appends racing 4 concurrent
compactions on one document with every update asserted to survive — plus nine checks in two
real Chromium tabs (`test/browser/convergence.mjs`) typing 30 characters each into the same
paragraph simultaneously:

```
ok   both tabs converge on the same text — 60 chars
ok   no keystrokes lost — 30 a + 30 b of 30 each
ok   the other caret is rendered — {"attached":true,"carets":1,"peers":2}
ok   compaction merged the log — Merged 63 updates
ok   editing still propagates after compaction
ok   a fresh tab loads the compacted document — 66 chars
```

That browser test earned its place: an earlier version of the demo synced whole blocks with
last-writer-wins resolution, passed the entire Elixir suite, and still dropped keystrokes —
because the failure only exists once two real editors are typing at once.

Both demos run in CI (`.github/workflows/ci.yml`), so a change to the library that breaks one
fails there rather than the next time somebody opens it. The editor demo runs its full suite
plus the two-browser test against a real server; the console demo is compiled against the
working tree, which is the failure that actually happens when the library renames something.

## Documentation

- [Design spec, staging plan, and verified constraints](docs/spec.md)
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
