defmodule AshCell.Manager do
  @moduledoc """
  Starts, finds, and evicts cells.

  Holds the fleet configuration (which repo module, where the files live, how to
  derive a cell's encryption key, how to migrate) so that callers only ever name a
  cell key.

  Everything here is keyed by *cell key*, never by tenant. Resolution from Ash's
  tenant happens once, at `AshCell.bind/1`, so by the time a request reaches this
  module the choice of how cells are cut has already been made and cannot vary.

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
    :snapshot,
    lru: %{},
    quarantined: %{},
    leases: %{},
    shipping: MapSet.new(),
    sealed?: false
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the running cell for `cell_key`, starting it if needed.

  Returns `{:error, :draining}` once the node has been sealed. An already-resident
  cell keeps serving while it drains, so in-flight work can finish; only *new*
  activations are refused.
  """
  def ensure_started(cell_key), do: ensure_started(cell_key, 50)

  defp ensure_started(cell_key, attempts_left) do
    case AshCell.Registry.lookup(cell_key) do
      {:ok, pid} ->
        # A registry hit is not proof of life. The entry outlives the process by
        # however long the registry takes to handle its DOWN, and a cell can also
        # be evicted or drained between one caller's lookup and its next call. Every
        # caller of this function then gets a `no process` exit from a GenServer it
        # never knew existed, nowhere near the code that closed the cell.
        if Process.alive?(pid) do
          touch(cell_key)
          {:ok, pid}
        else
          retry_start(cell_key, attempts_left)
        end

      :error ->
        GenServer.call(__MODULE__, {:start, cell_key}, 30_000)
    end
  end

  # Still a check-then-use, so it narrows the window rather than closing it --
  # nothing can promise a pid stays alive after being handed over. What it does
  # remove is the common case, where the process is already dead when we look.
  #
  # The sleep is the point. Registration is held via a `:via` tuple, so a cell that
  # dies without running `terminate/2` -- a crash, a kill -- stays in the registry
  # until the registry processes its DOWN. Retrying without yielding just reads the
  # same corpse a few microseconds later: the previous version spun three times
  # inside one scheduler slice and then gave up with `{:error, :cell_died}`, which
  # surfaced to callers as `:cell_unavailable` for a cell that was about to be
  # perfectly startable. It looked fine on an idle laptop, where the DOWN often
  # landed first, and failed on a loaded CI runner, where it did not.
  #
  # One millisecond at a time, up to 50, so the bound is ~50ms -- long enough for a
  # DOWN under load, short enough that a genuinely dead cell still fails promptly.
  defp retry_start(_cell_key, 0), do: {:error, :cell_died}

  defp retry_start(cell_key, attempts_left) do
    Process.sleep(1)
    ensure_started(cell_key, attempts_left - 1)
  end

  @doc """
  Stops this node taking on new cells.

  The first step of a drain. Without it the sweep races itself: a request arriving
  mid-drain reactivates a cell that was just handed over, and the node shuts down
  still holding a lease it believes it released.
  """
  def seal, do: GenServer.call(__MODULE__, :seal)

  @doc "Lets the node accept cells again. Mainly for tests."
  def unseal, do: GenServer.call(__MODULE__, :unseal)

  def sealed?, do: GenServer.call(__MODULE__, :sealed?)

  @doc "The configured object store, if this fleet replicates."
  def store, do: GenServer.call(__MODULE__, :store)

  @doc "The lease held for `cell_key`, if any."
  def lease(cell_key), do: GenServer.call(__MODULE__, {:lease, cell_key})

  @doc "The generation this node owns for `cell_key`, if any."
  def generation(cell_key) do
    case lease(cell_key) do
      nil -> nil
      lease -> lease.generation
    end
  end

  @doc """
  Reserves the next txid for `cell_key` from this node's local counter.

  Deliberately local. Reading the high-water mark from the object store here would
  undo the fence: a node that has lost the cell would read its successor's mark and
  write safely above it, so its conditional PUT would succeed and it would
  acknowledge a write that is about to be superseded. The mark is read once, when
  the lease is taken, and only advances through `committed/2`.

  Reserving also excludes a second concurrent shipment of the same cell. Two
  callers -- a periodic snapshot and a drain, say -- would otherwise both be handed
  the same number, and the loser's conditional PUT would be refused. That refusal is
  indistinguishable at the call site from being fenced by another *node*, so a
  harmless local overlap would read as "this node has lost the cell". Every reserve
  must be matched by `committed/2` or `abandoned/1`.

    * `{:error, :no_lease}` -- this node holds no lease, which is ordinary for a
      fleet with no object store
    * `{:error, :ship_in_flight}` -- somebody else is already shipping this cell
  """
  def claim_txid(cell_key), do: GenServer.call(__MODULE__, {:claim_txid, cell_key})

  @doc "Records a shipment that reached the store, advancing the local mark."
  def committed(cell_key, txid), do: GenServer.call(__MODULE__, {:committed, cell_key, txid})

  @doc """
  Records a shipment that did not reach the store, leaving the mark where it was.

  Not advancing is the point. The next attempt has to collide on the same txid, or
  a fenced writer would step past the successor that fenced it and start succeeding
  again.
  """
  def abandoned(cell_key), do: GenServer.call(__MODULE__, {:abandoned, cell_key})

  @doc false
  def put_lease(cell_key, lease), do: GenServer.call(__MODULE__, {:put_lease, cell_key, lease})

  @doc """
  Closes a cell. The database file is untouched.

  Waits briefly for in-flight work to finish first. Yanking a cell that a process
  is bound to does not merely interrupt a query -- the bound process is holding a
  repo pid, and its next call fails inside Ecto's registry with an error about
  ETS keys, nowhere near the code that closed the cell. Waiting turns a confusing
  crash into an ordinary pause.

  Pass `force: true` to close regardless, and expect bound callers to fail.

  Pass `await_repo?: true` if you are about to rewrite the database file. Without it
  this returns while the cell's SQLite connection is still shutting down, and the
  dying connection's checkpoint can land on top of your write. See
  `AshCell.Cell.stop_repo/1` for why it is not the default.
  """
  def close(cell_key, opts \\ []) do
    AshCell.Registry.begin_closing(cell_key)

    try do
      unless Keyword.get(opts, :force, false) do
        AshCell.Drain.await_quiescence(cell_key, Keyword.get(opts, :grace_ms, 1_000))
      end

      if Keyword.get(opts, :await_repo?, false), do: await_repo_stopped(cell_key)

      GenServer.call(__MODULE__, {:close, cell_key})
    after
      AshCell.Registry.end_closing(cell_key)
    end
  end

  @doc """
  Closes the cell and deletes its database, including the WAL sidecars.

  This is deletion in the literal sense: the bytes leave the filesystem. There is
  no VACUUM, no tombstone, and — provided the cell key identifies exactly what is
  being deleted — nobody else's data in the file. That proviso is the resolver's
  job: a coarser cut than per-tenant means this deletes more than one tenant.
  """
  def delete(cell_key), do: GenServer.call(__MODULE__, {:delete, cell_key})

  def config, do: GenServer.call(__MODULE__, :config)

  @doc """
  Cells that refused to start, with the reason.

  A lazily-migrated fleet fails one cell at a time, at whatever hour that cell
  next wakes up. Without somewhere to look, that is an outage nobody hears about,
  so quarantine is recorded rather than merely logged.
  """
  def quarantined, do: GenServer.call(__MODULE__, :quarantined)

  @doc "Clears a cell's quarantine so the next request retries activation."
  def release(cell_key), do: GenServer.call(__MODULE__, {:release, cell_key})

  @doc """
  Records that this node has been fenced out of `cell_key`, and stops serving it.

  Called when a shipment is refused, which is the only signal this node gets that
  somebody else owns the cell now. Until that moment being displaced is safe — the
  conditional write is what makes it safe. Afterwards it is not: every further
  write is one that cannot be shipped, and every read answers from a database whose
  real owner has moved on.

  So the cell is quarantined rather than merely closed. Closing alone would let the
  next request reactivate it from the same stale file, which is the failure this is
  trying to stop. Quarantine refuses activation until somebody clears it, which
  makes recovery deliberate: re-claim the lease, restore, then `release/1`.

  Fail-closed on purpose. Refusing to serve is recoverable and visible; serving
  data this node no longer owns is neither.

  The cell is closed as well as quarantined, and both are needed.
  `ensure_started/1` answers from the registry before it consults quarantine, so a
  cell that is already resident would go on serving every request that found it.
  Closed with `force: true`, because waiting for quiescence would mean waiting on
  work that must not be allowed to finish: an uncommitted transaction on a closed
  connection cannot commit, which is the outcome we want for a cell we do not own.
  """
  def fence(cell_key) do
    :ok = GenServer.call(__MODULE__, {:fence, cell_key})
    close(cell_key, force: true)
    :ok
  end

  @doc """
  Activates every cell in `cell_keys`, migrating each.

  Run at deploy time. Eager migration is the primary path precisely because it
  surfaces failures while someone is watching; lazy activation is the fallback for
  cells that were not in the list.
  """
  def migrate_all(cell_keys, opts \\ []) do
    close_after? = Keyword.get(opts, :close_after?, true)

    Enum.map(cell_keys, fn cell_key ->
      result =
        case ensure_started(cell_key) do
          {:ok, pid} ->
            info = AshCell.Cell.info(pid)
            if close_after?, do: close(cell_key)
            {:ok, info.schema_version}

          {:error, reason} ->
            {:error, reason}
        end

      {cell_key, result}
    end)
  end

  def path_for(cell_key), do: GenServer.call(__MODULE__, {:path_for, cell_key})

  defp touch(cell_key), do: GenServer.cast(__MODULE__, {:touch, cell_key})

  @impl true
  def init(opts) do
    state = %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      dir: Keyword.fetch!(opts, :dir),
      key_for: Keyword.get(opts, :key_for),
      migrator: Keyword.get(opts, :migrator),
      max_resident: Keyword.get(opts, :max_resident, @default_max_resident),
      store: Keyword.get(opts, :store),
      snapshot: AshCell.SnapshotPolicy.new(Keyword.get(opts, :snapshot), opts),
      owner: Keyword.get(opts, :owner, to_string(node()))
    }

    File.mkdir_p!(state.dir)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, _cell_key}, _from, %{sealed?: true} = state) do
    {:reply, {:error, :draining}, state}
  end

  # A quarantined tenant is refused without re-attempting the activation that
  # already failed. Retrying costs the same failure again -- a wrong key or a bad
  # migration is not transient -- and each attempt logs another crash, burying the
  # original cause. Clear it deliberately with release/1 once the cause is fixed.
  def handle_call({:start, cell_key}, _from, state)
      when is_map_key(state.quarantined, cell_key) do
    {:reply, {:error, {:quarantined, state.quarantined[cell_key]}}, state}
  end

  def handle_call({:start, cell_key}, _from, state) do
    # `Process.alive?` for the same reason `ensure_started/1` checks: a registry hit
    # is not proof of life, and handing back a corpse from here is worse, because a
    # caller that reached the manager has already been told the fast path failed.
    # Falling through to the start attempt is safe -- `start_child` answers
    # `{:error, {:already_started, pid}}` if the entry is still held.
    case AshCell.Registry.lookup(cell_key) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, mark(state, cell_key)}
        else
          {:reply, {:error, :cell_died}, state}
        end

      :error ->
        state = evict_if_needed(state)

        # Encryption is expected whenever the fleet was given a key function. The
        # cell uses `encrypted?` to tell "this fleet is unencrypted" apart from
        # "this cell's key is gone", which must fail rather than degrade.
        opts = [
          cell_key: cell_key,
          repo: state.repo,
          path: path(state, cell_key),
          key: key_for(state, cell_key),
          encrypted?: not is_nil(state.key_for),
          migrator: state.migrator,
          store: state.store,
          policy: state.snapshot
        ]

        spec = {AshCell.Cell, opts}

        case DynamicSupervisor.start_child(AshCell.CellSupervisor, spec) do
          {:ok, pid} ->
            {:reply, {:ok, pid}, state |> mark(cell_key) |> unquarantine(cell_key)}

          {:error, {:already_started, pid}} ->
            {:reply, {:ok, pid}, state |> mark(cell_key) |> unquarantine(cell_key)}

          {:error, reason} ->
            {:reply, {:error, reason}, quarantine(state, cell_key, reason)}
        end
    end
  end

  def handle_call({:close, cell_key}, _from, state) do
    stop_cell(cell_key)
    AshCell.Registry.forget(cell_key)

    {:reply, :ok,
     %{state | lru: Map.delete(state.lru, cell_key), leases: Map.delete(state.leases, cell_key)}}
  end

  def handle_call({:delete, cell_key}, _from, state) do
    stop_cell(cell_key)
    base = path(state, cell_key)

    # Closing the cell checkpoints and may remove the WAL sidecars itself, so
    # existence is not stable between the check and the removal. Attempt the
    # delete and report what actually went.
    removed =
      for suffix <- ["", "-wal", "-shm"],
          path = base <> suffix,
          File.rm(path) == :ok do
        path
      end

    {:reply, {:ok, removed}, %{state | lru: Map.delete(state.lru, cell_key)}}
  end

  def handle_call(:config, _from, state) do
    {:reply, Map.take(state, [:repo, :dir, :max_resident]), state}
  end

  def handle_call({:path_for, cell_key}, _from, state), do: {:reply, path(state, cell_key), state}

  def handle_call(:seal, _from, state), do: {:reply, :ok, %{state | sealed?: true}}
  def handle_call(:unseal, _from, state), do: {:reply, :ok, %{state | sealed?: false}}
  def handle_call(:sealed?, _from, state), do: {:reply, state.sealed?, state}
  def handle_call(:store, _from, state), do: {:reply, state.store, state}
  def handle_call({:lease, cell_key}, _from, state), do: {:reply, state.leases[cell_key], state}

  def handle_call({:put_lease, cell_key, lease}, _from, state) do
    {:reply, :ok, %{state | leases: Map.put(state.leases, cell_key, lease)}}
  end

  def handle_call({:claim_txid, cell_key}, _from, state) do
    cond do
      is_nil(state.leases[cell_key]) ->
        {:reply, {:error, :no_lease}, state}

      MapSet.member?(state.shipping, cell_key) ->
        {:reply, {:error, :ship_in_flight}, state}

      true ->
        txid = (state.leases[cell_key].txid || 0) + 1
        {:reply, {:ok, txid}, %{state | shipping: MapSet.put(state.shipping, cell_key)}}
    end
  end

  def handle_call({:committed, cell_key, txid}, _from, state) do
    state = %{state | shipping: MapSet.delete(state.shipping, cell_key)}

    case state.leases[cell_key] do
      nil ->
        {:reply, :ok, state}

      lease ->
        {:reply, :ok, %{state | leases: Map.put(state.leases, cell_key, %{lease | txid: txid})}}
    end
  end

  def handle_call({:abandoned, cell_key}, _from, state) do
    {:reply, :ok, %{state | shipping: MapSet.delete(state.shipping, cell_key)}}
  end

  def handle_call(:quarantined, _from, state), do: {:reply, state.quarantined, state}

  def handle_call({:release, cell_key}, _from, state),
    do: {:reply, :ok, unquarantine(state, cell_key)}

  def handle_call({:fence, cell_key}, _from, state) do
    # The lease goes too. Keeping it would leave this node renewing ownership of a
    # cell it has been told it does not have, and would let a later drain try to
    # ship again -- collide again -- for as long as the process lived.
    {:reply, :ok,
     %{
       state
       | leases: Map.delete(state.leases, cell_key),
         shipping: MapSet.delete(state.shipping, cell_key),
         quarantined: Map.put(state.quarantined, cell_key, :fenced)
     }}
  end

  @impl true
  def handle_cast({:touch, cell_key}, state), do: {:noreply, mark(state, cell_key)}

  # Best effort by design: if the cell is already gone there is no connection left
  # to wait for, which is the state the caller wanted anyway.
  defp await_repo_stopped(cell_key) do
    case AshCell.Registry.lookup(cell_key) do
      {:ok, pid} -> if Process.alive?(pid), do: AshCell.Cell.stop_repo(pid)
      :error -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp stop_cell(cell_key) do
    case AshCell.Registry.lookup(cell_key) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(AshCell.CellSupervisor, pid)
      :error -> :ok
    end
  end

  defp quarantine(state, cell_key, reason) do
    %{state | quarantined: Map.put(state.quarantined, cell_key, reason)}
  end

  defp unquarantine(state, cell_key) do
    %{state | quarantined: Map.delete(state.quarantined, cell_key)}
  end

  defp mark(state, cell_key),
    do: %{state | lru: Map.put(state.lru, cell_key, System.monotonic_time())}

  defp evict_if_needed(state) do
    if AshCell.Registry.count() >= state.max_resident do
      resident = MapSet.new(AshCell.Registry.resident_cells())

      state.lru
      |> Enum.filter(fn {cell_key, _} -> MapSet.member?(resident, cell_key) end)
      # Never evict a cell somebody is using. Least-recently-*started* is not the
      # same as unused: a LiveView can hold a cell open for hours while barely
      # touching it, and evicting it breaks the holder rather than freeing memory
      # that was actually idle.
      |> Enum.reject(fn {cell_key, _} -> AshCell.Registry.active_binds(cell_key) > 0 end)
      |> Enum.min_by(fn {_, at} -> at end, fn -> nil end)
      |> case do
        {cell_key, _} ->
          stop_cell(cell_key)
          %{state | lru: Map.delete(state.lru, cell_key)}

        nil ->
          state
      end
    else
      state
    end
  end

  # Encoded, never interpolated. A cell key is application-supplied, and
  # interpolating it put both a traversal ("../../x" wrote outside state.dir) and a
  # collision ("a:b" and "a_b" sharing one file) one careless key away.
  defp path(state, cell_key), do: Path.join(state.dir, AshCell.CellKey.encode(cell_key) <> ".db")

  defp key_for(%{key_for: nil}, _cell_key), do: nil
  defp key_for(%{key_for: fun}, cell_key), do: fun.(cell_key)
end
