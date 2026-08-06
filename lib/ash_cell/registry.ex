defmodule AshCell.Registry do
  @moduledoc """
  Maps a tenant to its resident cell process, and counts who is using it.

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

  def via(tenant), do: {:via, Registry, {__MODULE__, tenant}}

  def lookup(tenant) do
    case Registry.lookup(__MODULE__, tenant) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  def resident_tenants do
    Registry.select(__MODULE__, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def count, do: Registry.count(__MODULE__)

  @doc "Records that a process has bound `tenant`."
  def bound(tenant), do: bump(tenant, 1)

  @doc """
  Records that a process has released `tenant`.

  Floors at zero. A stray unbind — a double restore, or a crash cleaned up twice —
  must not drive the count negative, because a negative count reads as quiescent
  and would let a drain proceed over live work.
  """
  def unbound(tenant) do
    case bump(tenant, -1) do
      n when n < 0 -> :ets.insert(@binds, {tenant, 0})
      _ -> :ok
    end

    :ok
  end

  @doc "How many processes currently hold a binding for `tenant`."
  def active_binds(tenant) do
    case :ets.lookup(@binds, tenant) do
      [{^tenant, count}] -> max(count, 0)
      [] -> 0
    end
  end

  @doc "Bind counts for every tenant with outstanding work."
  def active_fleet do
    @binds
    |> :ets.tab2list()
    |> Enum.reject(fn {_tenant, count} -> count <= 0 end)
    |> Map.new()
  end

  @doc false
  def forget(tenant), do: :ets.delete(@binds, tenant)

  defp bump(tenant, delta) do
    :ets.update_counter(@binds, tenant, {2, delta}, {tenant, 0})
  end
end
