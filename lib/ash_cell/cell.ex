defmodule AshCell.Cell do
  @moduledoc """
  One tenant's database, owned by one process.

  The cell starts an `Ecto.Repo` *instance* (`start_link(name: nil, ...)`) against
  that tenant's own SQLite file and holds it for the cell's lifetime. Callers never
  talk to this process to run queries; they ask for the repo pid and bind it into
  their own process with `Ecto.Repo.put_dynamic_repo/1`, which is the only way Ecto
  routes a module call to a specific instance.

  Owning the repo here rather than in the caller means the connection outlives any
  one request, so a warm tenant is genuinely warm, and it dies with the cell rather
  than leaking when a caller crashes.
  """
  use GenServer, restart: :temporary

  require Logger

  defstruct [:tenant, :repo, :repo_pid, :path, :opened_at, queries: 0]

  def start_link(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    GenServer.start_link(__MODULE__, opts, name: AshCell.Registry.via(tenant))
  end

  @doc "The repo instance pid for this cell. Bind it with `put_dynamic_repo/1`."
  def repo_pid(pid), do: GenServer.call(pid, :repo_pid)

  @doc "Snapshot of this cell's state, for the fleet view."
  def info(pid), do: GenServer.call(pid, :info)

  def note_query(pid), do: GenServer.cast(pid, :note_query)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    tenant = Keyword.fetch!(opts, :tenant)
    repo = Keyword.fetch!(opts, :repo)
    path = Keyword.fetch!(opts, :path)
    key = Keyword.get(opts, :key)
    migrator = Keyword.get(opts, :migrator)

    File.mkdir_p!(Path.dirname(path))

    repo_opts =
      [name: nil, database: path, pool_size: 1]
      |> maybe_put_key(key)

    with {:ok, repo_pid} <- repo.start_link(repo_opts),
         :ok <- migrate(repo, repo_pid, migrator) do
      {:ok,
       %__MODULE__{
         tenant: tenant,
         repo: repo,
         repo_pid: repo_pid,
         path: path,
         opened_at: System.monotonic_time(:millisecond)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp maybe_put_key(opts, nil), do: opts
  defp maybe_put_key(opts, key), do: Keyword.put(opts, :key, key)

  # Migration runs before the cell is available, so a tenant is never served
  # against a half-migrated schema. A failure here stops the cell rather than
  # letting it answer queries.
  defp migrate(_repo, _repo_pid, nil), do: :ok

  defp migrate(repo, repo_pid, migrator) do
    previous = repo.get_dynamic_repo()
    repo.put_dynamic_repo(repo_pid)

    try do
      migrator.(repo_pid)
      :ok
    rescue
      e ->
        Logger.error("cell migration failed: #{Exception.message(e)}")
        {:error, {:migration_failed, e.__struct__}}
    after
      repo.put_dynamic_repo(previous)
    end
  end

  @impl true
  def handle_call(:repo_pid, _from, state), do: {:reply, state.repo_pid, state}

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       tenant: state.tenant,
       path: state.path,
       queries: state.queries,
       bytes: file_size(state.path),
       resident_ms: System.monotonic_time(:millisecond) - state.opened_at
     }, state}
  end

  @impl true
  def handle_cast(:note_query, state), do: {:noreply, %{state | queries: state.queries + 1}}

  @impl true
  def handle_info({:EXIT, pid, reason}, %{repo_pid: pid} = state) do
    {:stop, reason, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
