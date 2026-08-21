defmodule AshCell.Registry do
  @moduledoc """
  Maps a cell key to its resident cell process, and counts who is using it.

  The bind count exists for draining. Queries never pass through the cell process
  — they go straight to the repo instance — so a cell has no way to know whether
  anyone is mid-query. Without a count, a graceful shutdown is indistinguishable
  from a kill.

  It is an ETS counter rather than process state because it sits on the hot path:
  every `AshCell.bind/1` touches it, and a `GenServer.call` per bind would put a
  single process in front of every tenanted query in the system.
  """

  @binds __MODULE__.Binds

  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {__MODULE__, :start_link, []}
    }
  end

  def start_link do
    # Public and write-concurrent: bind/unbind run from arbitrary caller
    # processes, not from one owner.
    :ets.new(@binds, [:named_table, :public, :set, write_concurrency: true])
    Registry.start_link(keys: :unique, name: __MODULE__)
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
  def begin_closing(cell_key), do: :ets.insert(@binds, {closing_key(cell_key), true})

  @doc "Clears the closing mark for `cell_key`."
  def end_closing(cell_key), do: :ets.delete(@binds, closing_key(cell_key))

  @doc "Whether `cell_key` is being closed right now."
  def closing?(cell_key), do: :ets.member(@binds, closing_key(cell_key))

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
  How many processes are using `tenant` right now.

  Two populations, counted differently because they behave differently:

    * **transient binds** from `AshCell.with_tenant/2` — bracketed, so a counter
      is exact and cheap
    * **holders** from `AshCell.bind_held/1` — long-lived processes like
      LiveViews, tracked by `AshCell.Holders` so that a closed browser tab cleans
      itself up

  A drain waits on the sum. Counting only the transient half would report a cell
  as idle between a user's keystrokes.
  """
  def active_binds(cell_key) do
    transient =
      case :ets.lookup(@binds, cell_key) do
        [{^cell_key, count}] -> max(count, 0)
        [] -> 0
      end

    transient + AshCell.Holders.count(cell_key)
  end

  @doc "Transient bind count only, ignoring long-lived holders."
  def transient_binds(cell_key) do
    case :ets.lookup(@binds, cell_key) do
      [{^cell_key, count}] -> max(count, 0)
      [] -> 0
    end
  end

  @doc "Bind counts for every cell_key with outstanding work."
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
