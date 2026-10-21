defmodule AshCell.Registry do
  @moduledoc """
  Maps a cell key to its resident cell process, and counts who is using it.

  The counts exist for draining. Queries never pass through the cell process
  — they go straight to the repo instance — so a cell has no way to know whether
  anyone is mid-query. Without a count, a graceful shutdown is indistinguishable
  from a kill.

  Statements issued by the data layer are counted by the cell's connection pool,
  which is the one place that sees each of them start and finish. Explicit binds
  from `AshCell.with_tenant/2` are counted here, in an ETS counter rather than
  process state, because a `GenServer.call` per bind would put a single process in
  front of every one.

  It also maps a cell's repo instance back to its cell key, which is how
  `AshCell.bound_cell/0` answers from the process's Ecto binding alone.
  """

  @binds __MODULE__.Binds
  @repos __MODULE__.Repos

  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {__MODULE__, :start_link, []}
    }
  end

  @doc false
  def repos_child_spec, do: Registry.child_spec(keys: :unique, name: @repos)

  def start_link do
    # Public and write-concurrent: bind/unbind run from arbitrary caller
    # processes, not from one owner.
    :ets.new(@binds, [:named_table, :public, :set, write_concurrency: true])
    Registry.start_link(keys: :unique, name: __MODULE__)
  end

  @doc """
  Records `repo_pid` as the repo instance of `cell_key`. Called by the cell itself.

  Registered by the cell process, so both directions disappear when the cell dies
  without anything having to clean up after a crash.
  """
  def put_repo(cell_key, repo_pid) do
    {_, _} = Registry.update_value(__MODULE__, cell_key, fn _ -> repo_pid end)
    {:ok, _} = Registry.register(@repos, repo_pid, cell_key)
    :ok
  end

  @doc "Forgets the repo instance of `cell_key`, once the cell has stopped it."
  def drop_repo(cell_key, repo_pid) do
    Registry.update_value(__MODULE__, cell_key, fn _ -> nil end)
    Registry.unregister(@repos, repo_pid)
    :ok
  end

  @doc "The cell key whose repo instance is `repo_pid`, or `nil`."
  def cell_for_repo(repo_pid) do
    case Registry.lookup(@repos, repo_pid) do
      [{_cell, cell_key}] -> cell_key
      [] -> nil
    end
  end

  def via(cell_key), do: {:via, Registry, {__MODULE__, cell_key}}

  def lookup(cell_key) do
    case Registry.lookup(__MODULE__, cell_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def resident_cells do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def count, do: Registry.count(__MODULE__)

  @doc """
  Marks `tenant` as closing, so no new work binds to it.

  Waiting for quiescence is not enough on its own: the count can reach zero and a
  new binder arrive before the close lands. Closing has to *stop* new binds, not
  merely observe their absence.
  """
  def begin_closing(cell_key), do: :ets.insert(@binds, {closing_key(cell_key), self()})

  @doc "Clears the closing mark for `cell_key`."
  def end_closing(cell_key), do: :ets.delete(@binds, closing_key(cell_key))

  @doc """
  Whether `cell_key` is being closed by another process right now.

  The process that is closing it is let through, so a drain can still checkpoint and
  ship the cell it has stopped everyone else from binding.
  """
  def closing?(cell_key) do
    case :ets.lookup(@binds, closing_key(cell_key)) do
      [{_, closer}] -> closer != self()
      [] -> false
    end
  end

  defp closing_key(cell_key), do: {:closing, cell_key}

  @doc """
  Records that a process has bound `tenant`, unless it is closing.

  Returns `:ok`, or `:closing` so the caller can wait for the close to finish and
  bind to the cell that replaces it.
  """
  def bound(cell_key) do
    if closing?(cell_key) do
      :closing
    else
      bump(cell_key, 1)
      :ok
    end
  end

  @doc """
  Records that a process has released `tenant`.

  Floors at zero. A stray unbind — a double restore, or a crash cleaned up twice —
  must not drive the count negative, because a negative count reads as quiescent
  and would let a drain proceed over live work.
  """
  def unbound(cell_key) do
    case bump(cell_key, -1) do
      n when n < 0 -> :ets.insert(@binds, {cell_key, 0})
      _ -> :ok
    end

    :ok
  end

  @doc """
  How much work is using `cell_key` right now.

  Three populations, counted differently because they behave differently:

    * **transient binds** from `AshCell.with_tenant/2` — bracketed, so a counter
      is exact and cheap
    * **holders** from `AshCell.bind_held/1` — long-lived processes like
      LiveViews, tracked by `AshCell.Holders` so that a closed browser tab cleans
      itself up
    * **statements in flight** from the data layer — see `in_flight/1`

  A drain waits on the sum. Counting only the transient half would report a cell
  as idle between a user's keystrokes.
  """
  def active_binds(cell_key) do
    transient_binds(cell_key) + AshCell.Holders.count(cell_key) + in_flight(cell_key)
  end

  @doc """
  Statements holding or waiting for `cell_key`'s connection.

  Read from the connection pool rather than counted around each statement, because
  the data layer binds and restores a cell's repo itself and nothing of AshCell's
  runs after a statement finishes. A transaction holds the connection from its
  `BEGIN` to its `COMMIT`, so it counts for its whole length.

  It cannot see a statement whose cell has been resolved but which has not yet
  asked the pool for the connection. `scripts/tenant_repo_probe.exs` measures that
  window. A cell has `pool_size: 1`, which is what makes an idle pool mean zero.
  """
  def in_flight(cell_key) do
    with [{_cell, repo_pid}] when is_pid(repo_pid) <- Registry.lookup(__MODULE__, cell_key),
         %{pid: pool} <- Ecto.Adapter.lookup_meta(repo_pid) do
      pool
      |> DBConnection.get_connection_metrics()
      |> Enum.sum_by(&(1 - &1.ready_conn_count + &1.checkout_queue_length))
    else
      _ -> 0
    end
  rescue
    # The repo stopped between the lookup and the question. Nothing can be using
    # a connection that no longer exists.
    RuntimeError -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Transient bind count only, ignoring long-lived holders and statements."
  def transient_binds(cell_key) do
    case :ets.lookup(@binds, cell_key) do
      [{^cell_key, count}] -> max(count, 0)
      [] -> 0
    end
  end

  @doc "Transient bind counts for every cell with outstanding explicit binds."
  def active_fleet do
    @binds
    |> :ets.tab2list()
    |> Enum.reject(fn {_cell_key, count} -> count <= 0 end)
    |> Map.new()
  end

  @doc false
  def forget(cell_key), do: :ets.delete(@binds, cell_key)

  defp bump(cell_key, delta) do
    :ets.update_counter(@binds, cell_key, {2, delta}, {cell_key, 0})
  end
end
