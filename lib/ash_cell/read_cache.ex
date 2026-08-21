defmodule AshCell.ReadCache do
  @moduledoc """
  Per-cell cached projections, published in commit order, read without a message.

  A cell's reads serialise on its connection, and there is no widening the pool out
  of it: `scripts/read_pool_probe.exs` measures a realistic filtered join getting
  *worse* as the pool grows, because per-query overhead dominates and extra
  connections on one file add contention rather than parallelism. The read path has
  to be improved above SQLite, not inside it.

  Measured on the same probe, against the same file:

      pointer read, pool_size: 1        17.0 µs      59k reads/s
      pointer read, :persistent_term     0.04 µs     22M reads/s

  So the cache is not an optimisation, it is the difference between one node
  serving a fleet and one node serving a building.

  ## Why this is sound, which is the whole argument

  A cache in front of a shared database is a correctness problem: you cannot know
  when someone else wrote. A cell has exactly one writer, and this node is it, so
  the invalidation is not a guess.

  Reads go straight to `:persistent_term` — lock-free, zero-copy, from any process,
  with no mailbox to serialise on. Its one real cost is that *writes* trigger a
  global GC scan, which is exactly why it is the wrong store for most caches and
  the right one here. Writes are deploys.

  ## What guarantees the value is not stale

  Writes bracket themselves. `begin_write/1` erases the cell's entries and bumps its
  epoch before the statement runs; `end_write/2` bumps again *after* the commit. Both
  bumps matter and the second one is the subtle one: without it a reader could
  compute a projection from the pre-commit state, publish it while the write was
  still open, and leave that value in place after the commit landed.

  While a write is in flight, `publish/4` is refused outright. So a projection can
  only ever be published from a snapshot with no write open across it.

  Readers may populate the cache, which is safe because publishing is a
  compare-and-set on the epoch: a reader captures the epoch, computes, and its
  publish is dropped if anything has bumped it since. That means no projection
  registry and nothing to declare — writes invalidate, reads repopulate.

  A writer that dies between its commit and its `end_write/2` would otherwise leave
  a stale entry publishable forever, so writers are monitored and a `:DOWN` ends the
  write the same way returning does.

  ## What this does not cover

  Writes that do not go through the data layer. `AshCell.with_tenant/2` with raw
  Ecto, a `checkpoint/1`, a restore from a snapshot: none of those are statements
  this module sees, so they must call `invalidate/1` themselves. This is the same
  boundary `AshCell.Binder` has, for the same reason.

  This is a single node's cache. It says nothing about a replica on another node —
  see the `:replicated` and `:leased` strategies in `AshCell.ReadStrategy`.
  """
  use GenServer

  require Logger

  @type cell_key :: String.t()
  @type name :: term()
  @type token :: {reference(), non_neg_integer()}

  defstruct epochs: %{}, writers: %{}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cached projection `name` for this cell, or `:miss`.

  A `:persistent_term` lookup and nothing else — no `GenServer` call, no copy.
  """
  @spec fetch(cell_key(), name()) :: {:ok, term()} | :miss
  def fetch(cell_key, name) do
    case :persistent_term.get(entry(cell_key, name), :miss) do
      {:cached, value, _epoch} -> {:ok, value}
      :miss -> :miss
    end
  end

  @doc """
  Returns the cached projection `name`, computing it with `build` on a miss.

  `build` must be a pure function of the cell's committed state, because whether it
  runs at all depends on cache residency. It runs in the calling process, so a
  caller that needs the cell bound has to bind it — this module does not, since it
  cannot know whether `build` touches the database at all.

  The value it returns is published under the epoch captured *before* it ran, so a
  concurrent write discards it rather than overwriting a newer one.
  """
  @spec read(cell_key(), name(), (-> term())) :: term()
  def read(cell_key, name, build) when is_function(build, 0) do
    case fetch(cell_key, name) do
      {:ok, value} ->
        value

      :miss ->
        epoch = epoch(cell_key)
        value = build.()
        publish(cell_key, name, value, epoch)
        value
    end
  end

  @doc "The cell's current epoch, to be handed back to `publish/4`."
  @spec epoch(cell_key()) :: non_neg_integer()
  def epoch(cell_key), do: GenServer.call(__MODULE__, {:epoch, cell_key})

  @doc """
  Publishes `value` if the cell's epoch is still `epoch` and no write is open.

  Returns `:ok` if it was published and `:stale` if it was dropped. Dropping is the
  ordinary outcome under concurrency, not an error.
  """
  @spec publish(cell_key(), name(), term(), non_neg_integer()) :: :ok | :stale
  def publish(cell_key, name, value, epoch) do
    GenServer.call(__MODULE__, {:publish, cell_key, name, value, epoch})
  end

  @doc """
  Erases the cell's projections and bumps its epoch.

  For writes this module cannot see: raw Ecto through `AshCell.with_tenant/2`, a
  restore from a snapshot, anything that changes the file behind the data layer.
  """
  @spec invalidate(cell_key()) :: :ok
  def invalidate(cell_key) do
    GenServer.call(__MODULE__, {:invalidate, cell_key})
    :ok
  end

  @doc """
  Marks a write open on this cell: erases its projections, refuses publishes.

  Pair it with `end_write/2`. The caller is monitored, so a crash between the commit
  and `end_write/2` still ends the write rather than leaving a stale entry
  publishable.
  """
  @spec begin_write(cell_key()) :: token()
  def begin_write(cell_key), do: GenServer.call(__MODULE__, {:begin_write, cell_key})

  @doc "Ends a write opened with `begin_write/1`, bumping the epoch past the commit."
  @spec end_write(cell_key(), token()) :: :ok
  def end_write(cell_key, token) do
    GenServer.call(__MODULE__, {:end_write, cell_key, token})
    :ok
  end

  @doc """
  Runs `fun` with a write open on this cell.

  The bracket, which is what `AshCell.Binder` uses. Invalidates before and after,
  including when `fun` raises: a raise from a write is not proof the write did not
  land, so the cache has to assume it did.
  """
  @spec writing(cell_key(), (-> result)) :: result when result: var
  def writing(cell_key, fun) when is_function(fun, 0) do
    token = begin_write(cell_key)

    try do
      fun.()
    after
      end_write(cell_key, token)
    end
  end

  @doc false
  def entry(cell_key, name), do: {__MODULE__, cell_key, name}

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:epoch, cell_key}, _from, state) do
    {:reply, epoch_of(state, cell_key), state}
  end

  @impl true
  def handle_call({:publish, cell_key, name, value, epoch}, _from, state) do
    if epoch == epoch_of(state, cell_key) and not writing?(state, cell_key) do
      :persistent_term.put(entry(cell_key, name), {:cached, value, epoch})
      {:reply, :ok, state}
    else
      {:reply, :stale, state}
    end
  end

  @impl true
  def handle_call({:invalidate, cell_key}, _from, state) do
    {:reply, :ok, bump(state, cell_key)}
  end

  @impl true
  def handle_call({:begin_write, cell_key}, {pid, _tag}, state) do
    ref = Process.monitor(pid)
    state = bump(state, cell_key)

    state = %{state | writers: Map.put(state.writers, ref, cell_key)}

    {:reply, {ref, epoch_of(state, cell_key)}, state}
  end

  @impl true
  def handle_call({:end_write, cell_key, {ref, _epoch}}, _from, state) do
    Process.demonitor(ref, [:flush])

    {:reply, :ok, bump(%{state | writers: Map.delete(state.writers, ref)}, cell_key)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.writers, ref) do
      {nil, _} ->
        {:noreply, state}

      {cell_key, writers} ->
        # The write may or may not have committed. Either way the cache cannot
        # know, so it keeps nothing.
        {:noreply, bump(%{state | writers: writers}, cell_key)}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp epoch_of(state, cell_key), do: Map.get(state.epochs, cell_key, 0)

  defp writing?(state, cell_key), do: Enum.any?(state.writers, fn {_, c} -> c == cell_key end)

  # Erasing every entry for the cell rather than tracking which projections exist:
  # `:persistent_term` erasure costs a GC scan whether it is one key or ten, and a
  # cell has a handful of projections, not thousands.
  defp bump(state, cell_key) do
    for {{__MODULE__, ^cell_key, _name} = key, _} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    %{state | epochs: Map.put(state.epochs, cell_key, epoch_of(state, cell_key) + 1)}
  end
end
