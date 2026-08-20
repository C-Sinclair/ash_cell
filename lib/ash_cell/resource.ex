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

  One thing: it sets `tenant_binder AshCell.Binder` in the resource's `sqlite`
  section. Everything else is `AshSqlite.TenantBinder`, in the data layer, which
  asks the binder which connection to use once per statement.

  Setting `tenant_binder` yourself wins — the transformer only fills in a default.

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
  """

  use Spark.Dsl.Extension,
    transformers: [AshCell.Resource.Transformers.BindTenant],
    verifiers: [AshCell.Resource.Verifiers.VerifyMultitenancy]
end
