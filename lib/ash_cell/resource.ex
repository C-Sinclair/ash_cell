defmodule AshCell.Resource do
  @moduledoc """
  Marks a resource as living in a cell, and refuses it at compile time unless it can.

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

  With `MyApp.CellRepo` defined by `use AshCell.Repo`, an ordinary Ash call is
  enough, from anywhere, and no caller writes `with_tenant/2`:

      Ash.read!(MyApp.Patient, tenant: "acme")
      Ash.count!(MyApp.Patient, tenant: "acme")
      MyApp.Patient.create(attrs, tenant: "acme")

  ## What it actually does

  Very little, because the binding moved onto the repo. `use AshCell.Repo` makes
  the repo module answer `c:AshSqlite.Repo.tenant_repo/2`, and that is how the data
  layer learns which connection a tenanted statement runs on — once per statement,
  in the process about to issue it. The same module turns transactions on with
  `c:AshSqlite.Repo.write_transactions?/0`, so Ash wraps multi-step actions in a
  transaction instead of leaving a failed one half-applied. Ash passes the tenant
  to the data layer's `transaction/4` itself, so nothing has to carry it there.

  What is left for the extension is a compile-time check: `strategy :context`,
  with a message that says why a cell needs it. AshSqlite refuses the same resource
  too, because a tenant repo only serves context resources, but its message is
  about repos rather than cells.

  A transaction cannot span two cells: they are separate files on separate
  connections, and SQLite cannot commit across database files atomically in WAL
  mode. That case raises rather than committing half the work. `AshCell.transaction/2`
  is the way to put several actions in one transaction.

  ## Why the data layer rather than action hooks

  The first version of this extension installed `Ash.Query.around_transaction/2`
  and `Ash.Changeset.around_transaction/2` hooks from a global preparation and a
  global change. It worked for most calls and failed for three kinds, all of which
  are ordinary:

    * `Ash.read!(Resource, tenant: t)` on a bare resource. Preparations run inside
      `Ash.Query.for_read/4`, which for an unvalidated query Ash calls *inside*
      `do_run` — after it has already consumed the query's `around_transaction`
      hooks. The hook is installed past its own execution point and silently never
      runs.
    * `Ash.count/2` and the other aggregates, which run through
      `Ash.Actions.Aggregate` and never enter `Ash.Actions.Read` at all, so there
      are no action hooks to install.
    * Atomic updates and destroys. Ash calls `c:Ash.Resource.Change.atomic/3`
      *instead of* `c:Ash.Resource.Change.change/3` when it can build a single
      statement, and a changeset carrying an `around_transaction` hook is routed
      out of the batch path anyway. Keeping the hook meant `require_atomic? false`
      on every update and destroy.

  All three have the same shape: the caller cannot wrap a path it never sees. The
  data layer sees all of them, because they all end in a statement it issues, and
  at that point the tenant is in hand — in `query.__ash_bindings__.context` for
  reads and aggregates, on the changeset for writes.

  So the binding happens there, and this extension is thin. Atomic writes are on
  Ash's default path, aggregates work, and `Ash.read!/2` needs no ceremony.

  ## What this does not replace

  `AshCell.bind_held/1` for LiveViews. Its binding half is now redundant, but its
  other half registers the process as a *holder* so a drain warns it instead of
  counting the cell idle. That is a lifetime signal, not a connection choice, and
  nothing in the data layer knows about it.

  Anything that talks to a cell without going through a resource — `AshCell.checkpoint/1`,
  raw `Ecto.Adapters.SQL.query/3`, the benchmarks — still binds for itself.

  ## Resources that are not cells

  A shared table is a plain `AshSqlite.DataLayer` resource, not this extension:
  `strategy :context` is required here, because the tenant is how a cell is found.
  Transactions still work — a repo whose `write_transactions?/0` returns `true` is
  enough on its own, with nothing to bind.

  **It needs its own repo module, and AshSqlite enforces that.** Ecto keys the
  dynamic binding as `{repo_module, :dynamic_repo}`, so binding a cell affects
  exactly one module. A resource on a *different* repo module is immune to cell
  bindings by construction. One that shared the cells' repo module would inherit
  whatever the process happened to have bound, and its rows would land in that
  tenant's database — so AshSqlite refuses to compile a resource without
  `strategy :context` on a tenant repo. Both are pinned down in
  `test/non_tenanted_test.exs`.

  A transaction still cannot span the two, for the same reason it cannot span two
  cells: separate repos are separate connections, so a cell transaction and a
  shared-table transaction commit independently.
  """

  use Spark.Dsl.Extension, verifiers: [AshCell.Resource.Verifiers.VerifyMultitenancy]
end
