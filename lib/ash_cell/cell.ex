defmodule AshCell.Cell do
  @moduledoc """
  One cell's database, owned by one process.

  The cell starts an `Ecto.Repo` *instance* (`start_link(name: nil, ...)`) against
  that cell's own SQLite file and holds it for the cell's lifetime. Callers never
  talk to this process to run queries; they ask for the repo pid and bind it into
  their own process with `Ecto.Repo.put_dynamic_repo/1`, which is the only way Ecto
  routes a module call to a specific instance.

  Owning the repo here rather than in the caller means the connection outlives any
  one request, so a warm cell is genuinely warm, and it dies with the cell rather
  than leaking when a caller crashes.
  """
  use GenServer, restart: :temporary

  require Logger

  defstruct [:cell_key, :repo, :repo_pid, :path, :opened_at, :schema_version, queries: 0]

  def start_link(opts) do
    cell_key = Keyword.fetch!(opts, :cell_key)
    GenServer.start_link(__MODULE__, opts, name: AshCell.Registry.via(cell_key))
  end

  @doc "The repo instance pid for this cell. Bind it with `put_dynamic_repo/1`."
  def repo_pid(pid), do: GenServer.call(pid, :repo_pid)

  @doc "Snapshot of this cell's state, for the fleet view."
  def info(pid), do: GenServer.call(pid, :info)

  def note_query(pid), do: GenServer.cast(pid, :note_query)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    cell_key = Keyword.fetch!(opts, :cell_key)
    repo = Keyword.fetch!(opts, :repo)
    path = Keyword.fetch!(opts, :path)
    key = Keyword.get(opts, :key)
    migrator = Keyword.get(opts, :migrator)

    File.mkdir_p!(Path.dirname(path))

    repo_opts =
      # backoff_type: :stop makes an unopenable database fail immediately instead
      # of DBConnection retrying for seconds. A cell that cannot be opened is
      # almost never a transient condition -- it is a wrong or destroyed key, or a
      # corrupt file -- and retrying turns a clear failure into a hang.
      [name: nil, database: path, pool_size: 1, backoff_type: :stop]
      |> maybe_put_key(key)

    with :ok <- verify_key(key, Keyword.get(opts, :encrypted?, false)),
         {:ok, repo_pid} <- repo.start_link(repo_opts),
         {:ok, version} <- migrate(repo, repo_pid, migrator) do
      {:ok,
       %__MODULE__{
         cell_key: cell_key,
         repo: repo,
         repo_pid: repo_pid,
         path: path,
         schema_version: version,
         opened_at: System.monotonic_time(:millisecond)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp maybe_put_key(opts, nil), do: opts
  defp maybe_put_key(opts, key), do: Keyword.put(opts, :key, key)

  # A fleet that derives keys must never fall back to an unencrypted database
  # when a key is missing. SQLite will happily create a plaintext file for a
  # tenant whose key was destroyed, so the failure is silent and the result is
  # unencrypted data on disk under a name that says it is protected. Refuse.
  defp verify_key(nil, true), do: {:error, :no_key}
  defp verify_key(_key, _encrypted?), do: :ok

  # Migration runs before the cell is available, so a tenant is never served
  # against a half-migrated schema. A failure stops the cell rather than letting
  # it answer queries: being down is recoverable, serving an unknown schema is not.
  defp migrate(repo, repo_pid, migrator) do
    previous = repo.get_dynamic_repo()
    repo.put_dynamic_repo(repo_pid)

    try do
      AshCell.Migrator.apply_to(repo_pid, AshCell.Migrator.normalise(migrator))
    rescue
      e ->
        # Deliberately no tenant data in the message; a migration failure is
        # about schema, and the tenant id is enough to find the cell.
        Logger.error("cell migration raised: #{inspect(e.__struct__)}")
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
       cell_key: state.cell_key,
       path: state.path,
       queries: state.queries,
       schema_version: state.schema_version,
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
