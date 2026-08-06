defmodule AshCell do
  @moduledoc """
  Database-per-tenant SQLite for Ash.

  Each tenant is a *cell*: one SQLite file, optionally encrypted with that tenant's
  own key, owned by one process, with compute routed to the data rather than the
  reverse.

  ## The handle is the tenant id, not a pid

  Ecto binds a repo *instance* per process, and `c:Ecto.Repo.put_dynamic_repo/1`
  accepts only an atom or a pid — via-tuples are rejected by its guard, and
  `Ecto.Repo.Registry.lookup/1` resolves an atom through `GenServer.whereis/1`.
  Neither is a good handle to pass around:

    * a **pid** is unstable across cell restarts and cannot be serialised into a
      job payload
    * an **atom name** is stable and serialisable, but atoms are never garbage
      collected, so minting one per tenant leaks the atom table

  So the portable handle is the **tenant id itself**. `AshCell.Registry` resolves
  it to a live cell, starting one if needed, and the pid never leaves `bind/1`.
  That is what makes this work from any context — a controller, a LiveView, a
  `Task`, or an Oban job on a different node — with nothing inherited.

      AshCell.with_tenant("acme", fn ->
        MyApp.Patient |> Ash.read!(tenant: "acme")
      end)

  ## Binding is ambient, so bind explicitly

  Because Ecto's binding lives in the process dictionary, it does **not** survive
  `Task.async`, `Ash.load` fan-out, or a job boundary. Every entry point must bind
  for itself. Nothing should ever rely on inheriting a binding, and
  `assert_bound!/0` exists to make that a loud failure rather than a quiet one.
  """

  @tenant_key {__MODULE__, :bound_tenant}

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, type: :supervisor, start: {AshCell.Supervisor, :start_link, [opts]}}
  end

  @doc """
  Binds the calling process to `tenant`'s database, starting the cell if needed.

  Returns the previous binding so it can be restored. Prefer `with_tenant/2`
  unless you genuinely need to hold a binding across calls — for example inside a
  GenServer that only ever serves one tenant.
  """
  @spec bind(term()) :: {:ok, term()} | {:error, term()}
  def bind(tenant) do
    with {:ok, cell} <- AshCell.Manager.ensure_started(tenant) do
      repo = repo()
      previous = {repo.get_dynamic_repo(), Process.get(@tenant_key)}

      repo.put_dynamic_repo(AshCell.Cell.repo_pid(cell))
      Process.put(@tenant_key, tenant)
      AshCell.Cell.note_query(cell)
      AshCell.Registry.bound(tenant)

      {:ok, previous}
    end
  end

  @doc "Restores a binding returned by `bind/1`."
  @spec restore({term(), term()}) :: :ok
  def restore({dynamic_repo, tenant}) do
    # Release the binding this process currently holds before adopting the
    # previous one, so a nested with_tenant/2 decrements the inner tenant rather
    # than leaking a count that would make it look permanently busy to a drain.
    case Process.get(@tenant_key) do
      nil -> :ok
      current -> AshCell.Registry.unbound(current)
    end

    repo().put_dynamic_repo(dynamic_repo)

    case tenant do
      nil -> Process.delete(@tenant_key)
      other -> Process.put(@tenant_key, other)
    end

    :ok
  end

  @doc "Clears any tenant binding on this process."
  @spec unbind() :: :ok
  def unbind, do: restore({repo(), nil})

  @doc """
  Runs `fun` with the process bound to `tenant`'s database.

  Restores the previous binding afterwards, so nesting and re-entry are safe.
  """
  @spec with_tenant(term(), (-> result)) :: result when result: var
  def with_tenant(tenant, fun) when is_function(fun, 0) do
    {:ok, previous} = bind(tenant)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc """
  The tenant bound to this process, or `nil`.

  Read from the process dictionary rather than derived by searching the registry
  for a matching pid, so it stays correct when a cell restarts and gets a new pid.
  """
  @spec bound_tenant() :: term() | nil
  def bound_tenant, do: Process.get(@tenant_key)

  @doc """
  Raises unless this process is bound to a tenant.

  Use at the top of anything that will run tenanted queries but did not itself
  establish the binding — a background job, a spawned task, a consumer. Without
  it, an unbound query fails deep inside Ecto with a message about the repo not
  being started, which is technically fail-closed but tells you nothing about why.
  """
  @spec assert_bound!() :: term()
  def assert_bound! do
    case bound_tenant() do
      nil ->
        raise ArgumentError, """
        no AshCell tenant is bound to this process.

        The binding lives in the process dictionary and does not cross process
        boundaries, so a Task, an Oban job, or a spawned consumer starts unbound.
        Wrap the work:

            AshCell.with_tenant(tenant_id, fn -> ... end)
        """

      tenant ->
        tenant
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

  @doc """
  Hands every resident cell over and releases its lease.

  Call before the node goes away. Runs automatically on supervised shutdown; see
  `AshCell.Drain` for why the ordering inside it matters.
  """
  defdelegate drain(opts \\ []), to: AshCell.Drain, as: :run

  @doc "Per-cell stats for the resident fleet."
  def fleet do
    for tenant <- AshCell.Registry.resident_tenants(),
        {:ok, pid} <- [AshCell.Registry.lookup(tenant)] do
      AshCell.Cell.info(pid)
    end
  end

  @doc false
  def repo, do: AshCell.Manager.config().repo
end
