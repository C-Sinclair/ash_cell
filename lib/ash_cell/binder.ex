defmodule AshCell.Binder do
  @moduledoc """
  Implements `AshSqlite.TenantBinder` in terms of `AshCell.bind/1`.

  It also brackets writes for `AshCell.ReadCache`, which is the other thing only
  this seam can do: the data layer says whether a statement is a read or a write,
  and this is the last point at which that is known alongside the tenant.

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

  Re-resolving does not cost atomicity, which was the obvious worry. `AshCell.Resource`
  sets `transactions? true`, so Ash wraps a multi-step action in one transaction,
  and a transaction lives on one connection: while it is open, asking again for the
  same tenant returns the same cell repo pid and the statement lands inside the
  same `BEGIN`. A statement that would resolve to a *different* cell is refused
  rather than silently committing on its own — see `AshCell.transaction/2`.

  What re-resolving still cannot promise is that the cell survives the action — but
  the failure is now the safe one. A drain or eviction that takes the cell
  mid-transaction closes the connection the transaction is open on, and an
  uncommitted transaction on a closed connection cannot commit, so the action
  fails and the file never received any of it. Tested in
  `test/transaction_test.exs`, because "the work is lost" and "half the work is
  kept" are very different answers and the difference is the whole point.
  """

  @behaviour AshSqlite.TenantBinder

  @impl true
  def bind(tenant, opts, fun) do
    case AshCell.bind(tenant) do
      {:ok, previous} ->
        try do
          bracket(tenant, Keyword.get(opts, :usage, :write), fun)
        after
          AshCell.restore(previous)
        end

      {:error, reason} ->
        # Raising rather than running unbound. An unbound statement in a
        # database-per-tenant layout does not fail, it succeeds against the wrong
        # database, and the data layer has no way to tell that it has happened.
        raise AshCell.CellUnavailableError,
          cell_key: AshCell.CellKey.resolve(tenant),
          reason: reason
    end
  end

  # Reads run as they always did. Writes and the callback that opens a transaction
  # are bracketed, so `AshCell.ReadCache` erases the cell's projections before the
  # statement and again after it -- the second one being what stops a reader
  # publishing a pre-commit projection that outlives the commit.
  #
  # Defaulting an absent `:usage` to `:write` is deliberate: an unbracketed write
  # serves stale reads afterwards, and an over-bracketed read only loses a cache
  # entry.
  defp bracket(_tenant, :read, fun), do: fun.()

  defp bracket(tenant, usage, fun) when usage in [:write, :transaction] do
    AshCell.ReadCache.writing(AshCell.CellKey.resolve(tenant), fun)
  end
end
