defmodule AshCell.Binder do
  @moduledoc """
  Answers `c:AshSqlite.Repo.tenant_repo/2` for a cell repo: which repo instance a
  tenant's statement runs on.

  This is the whole of the integration. AshSqlite asks once per statement, in the
  process that is about to issue it; AshCell resolves the tenant to a cell key,
  starts the cell if it is not resident, and returns its repo instance. The data
  layer binds that instance for the statement and restores the previous binding
  afterwards. `use AshCell.Repo` wires a repo module to this.

  Because the data layer asks per statement, nothing above it has to remember to.
  A `Task`, a load fan-out, an Oban job, `Ash.count/2`, and an atomic UPDATE all
  arrive here the same way, which is why `AshCell.with_tenant/2` is not needed at
  call sites.

  ## Nothing runs after the statement

  The data layer calls in before a statement and not after it. Three things that
  used to be done around each statement are therefore done elsewhere:

    * the drain's in-flight count is read from the cell's connection pool —
      `AshCell.Registry.in_flight/1`
    * the read cache's write bracket is opened here and closed by the repo's
      query telemetry once the statement or its `COMMIT` has run —
      `AshCell.ReadCache.open_write/1`
    * the bound cell key is read off Ecto's binding rather than kept beside it —
      `AshCell.bound_cell/0`

  ## Re-resolving per statement

  Deliberate rather than merely tolerable. The binding is a repo *pid*, and a cell
  can be evicted, restarted, or drained between one statement and the next; a
  binding held across a whole action can therefore go stale mid-action. Asking
  again costs a registry lookup and a call to the cell.

  It does not cost atomicity. A cell repo has `write_transactions?/0` on, so Ash
  wraps a multi-step action in one transaction, and a transaction lives on one
  connection: while it is open, asking again for the same tenant returns the same
  repo pid and the statement lands inside the same `BEGIN`. A statement that would
  resolve to a *different* cell is refused by the data layer rather than silently
  committing on its own.

  What re-resolving cannot promise is that the cell survives the action, and the
  failure is the safe one. A drain or eviction that takes the cell mid-transaction
  closes the connection the transaction is open on, and an uncommitted transaction
  on a closed connection cannot commit, so the action fails and the file never
  received any of it. Tested in `test/transaction_test.exs`.
  """

  @doc """
  The repo instance for `tenant`'s cell. Raises `AshCell.CellUnavailableError`
  rather than returning an unbound repo.

  `context.type` is `:mutate` for a write or for opening a transaction, which opens
  a write on the cell for `AshCell.ReadCache`.
  """
  @spec tenant_repo(term(), %{type: :read | :mutate}) :: pid()
  def tenant_repo(tenant, %{type: type}) do
    cell_key = AshCell.CellKey.resolve(tenant)

    case AshCell.repo_for_cell(cell_key) do
      {:ok, repo_pid} ->
        if type == :mutate, do: AshCell.ReadCache.open_write(cell_key)
        repo_pid

      {:error, reason} ->
        # Raising rather than running unbound. An unbound statement in a
        # database-per-tenant layout does not fail, it succeeds against the wrong
        # database, and the data layer has no way to tell that it has happened.
        raise AshCell.CellUnavailableError, cell_key: cell_key, reason: reason
    end
  end
end
