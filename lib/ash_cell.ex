defmodule AshCell do
  @moduledoc """
  Database-per-tenant SQLite for Ash.

  Each tenant is a *cell*: one SQLite file, optionally encrypted with that tenant's
  own key, owned by one process, with compute routed to the data rather than the
  reverse.

  ## Using it

      children = [
        {AshCell, repo: MyApp.Repo, dir: "priv/cells", migrator: &MyApp.Migrations.run/1}
      ]

      AshCell.with_tenant("acme", fn ->
        MyApp.Patient |> Ash.read!(tenant: "acme")
      end)

  ## Why `with_tenant/2` and not an option on the query

  Ecto binds a repo *instance* per process, and both AshSqlite's read path
  (`repo.all/2`) and its write path (`repo.insert_all/3`) call the resolved repo as
  a module. So the tenant cannot travel on the query struct; it has to be
  established in the process that will run the query.

  That makes the binding ambient, which is a hazard worth naming: it does **not**
  survive `Task.async`, `Ash.load` fan-out, or a background job. Anything that
  crosses a process boundary must call `with_tenant/2` again on the other side.
  Nothing should ever rely on inheriting a binding.
  """

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {AshCell.Supervisor, :start_link, [opts]}
    }
  end

  @doc """
  Runs `fun` with the process bound to `tenant`'s database.

  Starts the cell if it is not resident. Restores the previous binding afterwards,
  so nesting and re-entry are safe.
  """
  @spec with_tenant(term(), (-> result)) :: result when result: var
  def with_tenant(tenant, fun) when is_function(fun, 0) do
    {:ok, cell} = AshCell.Manager.ensure_started(tenant)
    repo = repo()
    repo_pid = AshCell.Cell.repo_pid(cell)

    previous = repo.get_dynamic_repo()
    repo.put_dynamic_repo(repo_pid)
    AshCell.Cell.note_query(cell)

    try do
      fun.()
    after
      repo.put_dynamic_repo(previous)
    end
  end

  @doc "The tenant currently bound to this process, or `nil`."
  def current_tenant do
    bound = repo().get_dynamic_repo()

    Enum.find(AshCell.Registry.resident_tenants(), fn tenant ->
      match?({:ok, pid} when pid != nil, AshCell.Registry.lookup(tenant)) and
        cell_repo_pid(tenant) == bound
    end)
  end

  defp cell_repo_pid(tenant) do
    case AshCell.Registry.lookup(tenant) do
      {:ok, pid} -> AshCell.Cell.repo_pid(pid)
      :error -> nil
    end
  end

  @doc """
  Folds the tenant's write-ahead log into its main database file.

  In WAL mode a committed row lives in `<db>-wal` until a checkpoint moves it, so
  the `.db` file on its own is not the whole database. Anything that inspects,
  copies, or ships the file — replication, export, or proving on-disk contents —
  must checkpoint first or it will silently miss recent writes.
  """
  def checkpoint(tenant) do
    with_tenant(tenant, fn ->
      {:ok, pid} = AshCell.Manager.ensure_started(tenant)
      repo_pid = AshCell.Cell.repo_pid(pid)
      Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA wal_checkpoint(TRUNCATE)", [])
      :ok
    end)
  end

  @doc "Closes a tenant's cell, leaving its database on disk."
  defdelegate close(tenant), to: AshCell.Manager

  @doc "Closes a tenant's cell and deletes its database files."
  defdelegate delete(tenant), to: AshCell.Manager

  @doc "Absolute path of a tenant's database file."
  defdelegate path_for(tenant), to: AshCell.Manager

  @doc "Tenants with a resident (open) cell right now."
  defdelegate resident_tenants(), to: AshCell.Registry

  @doc "Per-cell stats for the resident fleet."
  def fleet do
    for tenant <- AshCell.Registry.resident_tenants(),
        {:ok, pid} <- [AshCell.Registry.lookup(tenant)] do
      AshCell.Cell.info(pid)
    end
  end

  defp repo, do: AshCell.Manager.config().repo
end
