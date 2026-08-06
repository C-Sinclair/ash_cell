defmodule AshCell.Manager do
  @moduledoc """
  Starts, finds, and evicts cells.

  Holds the fleet configuration (which repo module, where the files live, how to
  derive a tenant's key, how to migrate) so that callers only ever name a tenant.

  Residency is bounded. Cells are cheap but not free — each holds an open SQLite
  connection and its page cache — so once `max_resident` is reached the
  least-recently-used cell is closed to make room. Closing a cell drops its
  connection; the data is a file and stays exactly where it was.
  """
  use GenServer

  @default_max_resident 256

  defstruct [
    :repo,
    :dir,
    :key_for,
    :migrator,
    :max_resident,
    :store,
    :owner,
    lru: %{},
    quarantined: %{},
    leases: %{},
    sealed?: false
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the running cell for `tenant`, starting it if needed.

  Returns `{:error, :draining}` once the node has been sealed. An already-resident
  cell keeps serving while it drains, so in-flight work can finish; only *new*
  activations are refused.
  """
  def ensure_started(tenant) do
    case AshCell.Registry.lookup(tenant) do
      {:ok, pid} ->
        touch(tenant)
        {:ok, pid}

      :error ->
        GenServer.call(__MODULE__, {:start, tenant}, 30_000)
    end
  end

  @doc """
  Stops this node taking on new cells.

  The first step of a drain. Without it the sweep races itself: a request arriving
  mid-drain reactivates a tenant that was just handed over, and the node shuts down
  still holding a lease it believes it released.
  """
  def seal, do: GenServer.call(__MODULE__, :seal)

  @doc "Lets the node accept cells again. Mainly for tests."
  def unseal, do: GenServer.call(__MODULE__, :unseal)

  def sealed?, do: GenServer.call(__MODULE__, :sealed?)

  @doc "The configured object store, if this fleet replicates."
  def store, do: GenServer.call(__MODULE__, :store)

  @doc "The lease held for `tenant`, if any."
  def lease(tenant), do: GenServer.call(__MODULE__, {:lease, tenant})

  @doc "The generation this node owns for `tenant`, if any."
  def generation(tenant) do
    case lease(tenant) do
      nil -> nil
      lease -> lease.generation
    end
  end

  @doc false
  def put_lease(tenant, lease), do: GenServer.call(__MODULE__, {:put_lease, tenant, lease})

  @doc "Closes a tenant's cell. The database file is untouched."
  def close(tenant), do: GenServer.call(__MODULE__, {:close, tenant})

  @doc """
  Closes the cell and deletes the tenant's database, including its WAL sidecars.

  This is deletion in the literal sense: the bytes leave the filesystem. There is
  no VACUUM, no tombstone, and no other tenant's data in the file.
  """
  def delete(tenant), do: GenServer.call(__MODULE__, {:delete, tenant})

  def config, do: GenServer.call(__MODULE__, :config)

  @doc """
  Tenants whose cell refused to start, with the reason.

  A lazily-migrated fleet fails one tenant at a time, at whatever hour that tenant
  next wakes up. Without somewhere to look, that is an outage nobody hears about,
  so quarantine is recorded rather than merely logged.
  """
  def quarantined, do: GenServer.call(__MODULE__, :quarantined)

  @doc "Clears a tenant's quarantine so the next request retries activation."
  def release(tenant), do: GenServer.call(__MODULE__, {:release, tenant})

  @doc """
  Activates every tenant in `tenants`, migrating each.

  Run at deploy time. Eager migration is the primary path precisely because it
  surfaces failures while someone is watching; lazy activation is the fallback for
  tenants that were not in the list.
  """
  def migrate_all(tenants, opts \\ []) do
    close_after? = Keyword.get(opts, :close_after?, true)

    Enum.map(tenants, fn tenant ->
      result =
        case ensure_started(tenant) do
          {:ok, pid} ->
            info = AshCell.Cell.info(pid)
            if close_after?, do: close(tenant)
            {:ok, info.schema_version}

          {:error, reason} ->
            {:error, reason}
        end

      {tenant, result}
    end)
  end

  def path_for(tenant), do: GenServer.call(__MODULE__, {:path_for, tenant})

  defp touch(tenant), do: GenServer.cast(__MODULE__, {:touch, tenant})

  @impl true
  def init(opts) do
    state = %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      dir: Keyword.fetch!(opts, :dir),
      key_for: Keyword.get(opts, :key_for),
      migrator: Keyword.get(opts, :migrator),
      max_resident: Keyword.get(opts, :max_resident, @default_max_resident),
      store: Keyword.get(opts, :store),
      owner: Keyword.get(opts, :owner, to_string(node()))
    }

    File.mkdir_p!(state.dir)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, _tenant}, _from, %{sealed?: true} = state) do
    {:reply, {:error, :draining}, state}
  end

  def handle_call({:start, tenant}, _from, state) do
    case AshCell.Registry.lookup(tenant) do
      {:ok, pid} ->
        {:reply, {:ok, pid}, mark(state, tenant)}

      :error ->
        state = evict_if_needed(state)

        spec =
          {AshCell.Cell,
           tenant: tenant,
           repo: state.repo,
           path: path(state, tenant),
           key: key_for(state, tenant),
           migrator: state.migrator}

        case DynamicSupervisor.start_child(AshCell.CellSupervisor, spec) do
          {:ok, pid} ->
            {:reply, {:ok, pid}, state |> mark(tenant) |> unquarantine(tenant)}

          {:error, {:already_started, pid}} ->
            {:reply, {:ok, pid}, state |> mark(tenant) |> unquarantine(tenant)}

          {:error, reason} ->
            {:reply, {:error, reason}, quarantine(state, tenant, reason)}
        end
    end
  end

  def handle_call({:close, tenant}, _from, state) do
    stop_cell(tenant)
    AshCell.Registry.forget(tenant)

    {:reply, :ok,
     %{state | lru: Map.delete(state.lru, tenant), leases: Map.delete(state.leases, tenant)}}
  end

  def handle_call({:delete, tenant}, _from, state) do
    stop_cell(tenant)
    base = path(state, tenant)

    # Closing the cell checkpoints and may remove the WAL sidecars itself, so
    # existence is not stable between the check and the removal. Attempt the
    # delete and report what actually went.
    removed =
      for suffix <- ["", "-wal", "-shm"],
          path = base <> suffix,
          File.rm(path) == :ok do
        path
      end

    {:reply, {:ok, removed}, %{state | lru: Map.delete(state.lru, tenant)}}
  end

  def handle_call(:config, _from, state) do
    {:reply, Map.take(state, [:repo, :dir, :max_resident]), state}
  end

  def handle_call({:path_for, tenant}, _from, state), do: {:reply, path(state, tenant), state}

  def handle_call(:seal, _from, state), do: {:reply, :ok, %{state | sealed?: true}}
  def handle_call(:unseal, _from, state), do: {:reply, :ok, %{state | sealed?: false}}
  def handle_call(:sealed?, _from, state), do: {:reply, state.sealed?, state}
  def handle_call(:store, _from, state), do: {:reply, state.store, state}
  def handle_call({:lease, tenant}, _from, state), do: {:reply, state.leases[tenant], state}

  def handle_call({:put_lease, tenant, lease}, _from, state) do
    {:reply, :ok, %{state | leases: Map.put(state.leases, tenant, lease)}}
  end

  def handle_call(:quarantined, _from, state), do: {:reply, state.quarantined, state}

  def handle_call({:release, tenant}, _from, state),
    do: {:reply, :ok, unquarantine(state, tenant)}

  @impl true
  def handle_cast({:touch, tenant}, state), do: {:noreply, mark(state, tenant)}

  defp stop_cell(tenant) do
    case AshCell.Registry.lookup(tenant) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(AshCell.CellSupervisor, pid)
      :error -> :ok
    end
  end

  defp quarantine(state, tenant, reason) do
    %{state | quarantined: Map.put(state.quarantined, tenant, reason)}
  end

  defp unquarantine(state, tenant) do
    %{state | quarantined: Map.delete(state.quarantined, tenant)}
  end

  defp mark(state, tenant),
    do: %{state | lru: Map.put(state.lru, tenant, System.monotonic_time())}

  defp evict_if_needed(state) do
    if AshCell.Registry.count() >= state.max_resident do
      resident = MapSet.new(AshCell.Registry.resident_tenants())

      state.lru
      |> Enum.filter(fn {tenant, _} -> MapSet.member?(resident, tenant) end)
      |> Enum.min_by(fn {_, at} -> at end, fn -> nil end)
      |> case do
        {tenant, _} ->
          stop_cell(tenant)
          %{state | lru: Map.delete(state.lru, tenant)}

        nil ->
          state
      end
    else
      state
    end
  end

  defp path(state, tenant), do: Path.join(state.dir, "#{tenant}.db")

  defp key_for(%{key_for: nil}, _tenant), do: nil
  defp key_for(%{key_for: fun}, tenant), do: fun.(tenant)
end
