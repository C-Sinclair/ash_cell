defmodule AshCell.Resource do
  @moduledoc """
  Makes a tenanted resource bind its own cell, so callers never write `with_tenant/2`.

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

  With that, an ordinary Ash call is enough, from anywhere:

      Ash.read!(MyApp.Patient, tenant: "acme")
      Ash.count!(MyApp.Patient, tenant: "acme")
      MyApp.Patient.create(attrs, tenant: "acme")

  ## What it actually does

  Three things, all in the resource's `sqlite` section or its `changes`:

    * sets `tenant_binder AshCell.Binder`, which is how the data layer learns which
      connection a tenanted statement runs on — once per statement, in the process
      about to issue it
    * sets `transactions? true`, so Ash wraps multi-step actions in a transaction
      instead of leaving a failed one half-applied
    * adds `AshCell.Resource.Changes.CarryTenant`, because the one callback that
      opens the transaction runs above the data layer and so cannot read the tenant
      off a changeset the way every other callback does

  Setting `tenant_binder` or `transactions?` yourself wins — the transformer only
  fills in defaults. `transactions? false` gets you the old behaviour, where a
  multi-step action was never atomic.

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

  So the binding now happens there, and this extension is thin. Atomic writes are
  back to Ash's default, aggregates work, and `Ash.read!/2` needs no ceremony.

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
  Transactions still work — `transactions? true` in the `sqlite` section is enough
  on its own, with nothing to bind.

  **Give it its own repo module.** Ecto keys the dynamic binding as
  `{repo_module, :dynamic_repo}`, so binding a cell affects exactly one module. A
  non-tenanted resource on a *different* repo module is immune to cell bindings by
  construction. One that shares the cells' repo module inherits whatever the
  process happens to have bound, and its rows land in that tenant's database —
  silently, because nothing in the stack can tell that a shared row was meant to be
  shared. Both behaviours are pinned down in `test/non_tenanted_test.exs`.

  A transaction still cannot span the two, for the same reason it cannot span two
  cells: separate repos are separate connections, so a cell transaction and a
  shared-table transaction commit independently.
  """

  use Spark.Dsl.Extension,
    transformers: [AshCell.Resource.Transformers.BindTenant],
    verifiers: [AshCell.Resource.Verifiers.VerifyMultitenancy]
end
