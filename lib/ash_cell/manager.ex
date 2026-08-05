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

  defstruct [:repo, :dir, :key_for, :migrator, :max_resident, lru: %{}]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the running cell for `tenant`, starting it if needed."
  def ensure_started(tenant) do
    case AshCell.Registry.lookup(tenant) do
      {:ok, pid} ->
        touch(tenant)
        {:ok, pid}

      :error ->
        GenServer.call(__MODULE__, {:start, tenant}, 30_000)
    end
  end

  @doc "Closes a tenant's cell. The database file is untouched."
  def close(tenant), do: GenServer.call(__MODULE__, {:close, tenant})

  @doc """
  Closes the cell and deletes the tenant's database, including its WAL sidecars.

  This is deletion in the literal sense: the bytes leave the filesystem. There is
  no VACUUM, no tombstone, and no other tenant's data in the file.
  """
  def delete(tenant), do: GenServer.call(__MODULE__, {:delete, tenant})

  def config, do: GenServer.call(__MODULE__, :config)

  def path_for(tenant), do: GenServer.call(__MODULE__, {:path_for, tenant})

  defp touch(tenant), do: GenServer.cast(__MODULE__, {:touch, tenant})

  @impl true
  def init(opts) do
    state = %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      dir: Keyword.fetch!(opts, :dir),
      key_for: Keyword.get(opts, :key_for),
      migrator: Keyword.get(opts, :migrator),
      max_resident: Keyword.get(opts, :max_resident, @default_max_resident)
    }

    File.mkdir_p!(state.dir)
    {:ok, state}
  end

  @impl true
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
          {:ok, pid} -> {:reply, {:ok, pid}, mark(state, tenant)}
          {:error, {:already_started, pid}} -> {:reply, {:ok, pid}, mark(state, tenant)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:close, tenant}, _from, state) do
    stop_cell(tenant)
    {:reply, :ok, %{state | lru: Map.delete(state.lru, tenant)}}
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

  @impl true
  def handle_cast({:touch, tenant}, state), do: {:noreply, mark(state, tenant)}

  defp stop_cell(tenant) do
    case AshCell.Registry.lookup(tenant) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(AshCell.CellSupervisor, pid)
      :error -> :ok
    end
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
