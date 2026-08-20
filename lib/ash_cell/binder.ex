defmodule AshCell.Binder do
  @moduledoc """
  Implements `AshSqlite.TenantBinder` in terms of `AshCell.bind/1`.

  This is the whole of the integration. AshSqlite asks "which connection does this
  tenant's statement run on", once per statement, in the process that is about to
  issue it; AshCell answers by starting the cell if it is not resident and binding
  its repo instance.

  Because the data layer asks per statement, nothing above it has to remember to.
  A `Task`, a load fan-out, an Oban job, `Ash.count/2`, and an atomic UPDATE all
  arrive here the same way, which is why `AshCell.with_tenant/2` is no longer
  needed at call sites.

  ## Re-entrancy and the cost of asking every time

  `bind/2` nests: `AshCell.bind/1` returns the previous binding and `restore/1`
  puts it back, so an action that issues several statements binds and releases
  several times without the counts drifting.

  Re-resolving per statement is deliberate rather than merely tolerable. The
  binding is a repo *pid*, and a cell can be evicted, restarted, or drained between
  one statement and the next; a binding held across a whole action can therefore go
  stale mid-action. Asking again costs a registry lookup and a process-dictionary
  write.

  What it does not give you is a guarantee that a multi-statement action runs
  entirely against one instance of a cell. It cannot: AshSqlite reports
  `can?(:transact) → false`, so a multi-step action was never atomic here, and a
  drain can land between two of its statements. That is a real gap and it is the
  same gap the workspace overview already records — the binder does not widen it,
  but it does not close it either.
  """

  @behaviour AshSqlite.TenantBinder

  @impl true
  def bind(tenant, fun) do
    case AshCell.bind(tenant) do
      {:ok, previous} ->
        try do
          fun.()
        after
          AshCell.restore(previous)
        end

      {:error, reason} ->
        # Raising rather than running unbound. An unbound statement in a
        # database-per-tenant layout does not fail, it succeeds against the wrong
        # database, and the data layer has no way to tell that it has happened.
        raise AshCell.CellUnavailableError, tenant: tenant, reason: reason
    end
  end
end
