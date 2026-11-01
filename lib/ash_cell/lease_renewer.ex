defmodule AshCell.LeaseRenewer do
  @moduledoc """
  Renews every lease this node holds, and releases them.

  A lease that is not renewed expires after its TTL while this node keeps serving
  the cell, and another node's claim then succeeds. Each lease the manager holds is
  renewed once `AshCell.Ownership.renew_due?/1` says so, which is when less than a
  third of its TTL is left. A renewal refused because another owner holds the lease
  fences the cell with `AshCell.Manager.fence/1`.

  `AshCell.Drain` releases leases through `release/2`, so a renewal never races the
  release of the same lease.
  """
  use GenServer

  require Logger

  alias AshCell.{Lease, Manager, Ownership}

  @idle_tick_ms 250
  @min_tick_ms 50
  @max_tick_ms 1_000
  @concurrency 16

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Releases the lease this node holds for `cell_key` in `store`, and forgets it.

  Returns `:ok` when no lease is held, `{:error, :lease_taken}` when another owner
  holds the lease, and the store's error otherwise. The cell is not fenced here.
  """
  def release(cell_key, store),
    do: GenServer.call(__MODULE__, {:release, cell_key, store}, 30_000)

  @impl true
  def init(_opts) do
    schedule(@idle_tick_ms)
    {:ok, %{held: %{}}}
  end

  @impl true
  def handle_call({:release, cell_key, store}, _from, state) do
    state = %{state | held: Map.delete(state.held, cell_key)}

    case Manager.lease(cell_key) do
      nil ->
        {:reply, :ok, state}

      lease ->
        case Lease.release(store, lease) do
          :ok ->
            Manager.released(cell_key, lease.etag)
            {:reply, :ok, state}

          {:error, :precondition_failed} ->
            {:reply, {:error, :lease_taken}, state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_info(:tick, state) do
    leases = Manager.leases()

    held =
      Map.new(leases, fn {cell_key, lease} ->
        {cell_key, tracked(state.held[cell_key], lease)}
      end)

    held =
      held
      |> Enum.filter(fn {_cell_key, ownership} -> Ownership.renew_due?(ownership) end)
      |> Task.async_stream(fn {cell_key, ownership} -> {cell_key, renew(cell_key, ownership)} end,
        max_concurrency: @concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce(held, fn {:ok, {cell_key, result}}, held ->
        record(held, cell_key, result)
      end)

    schedule(tick_ms(leases))
    {:noreply, %{state | held: held}}
  end

  # Re-derived whenever the etag changes, because a claim on this node can replace
  # the lease without coming through here.
  defp tracked(%Ownership{lease: %{etag: etag}} = ownership, %{etag: etag}), do: ownership

  defp tracked(_ownership, lease) do
    ttl_ms = lease.ttl_ms || Lease.default_ttl_ms()
    # This node wrote `expires_at`, so its own wall clock measures what is left.
    remaining = max(lease.expires_at - System.system_time(:millisecond), 0)

    %{
      Ownership.held(lease, ttl_ms)
      | expires_at_monotonic: System.monotonic_time(:millisecond) + remaining
    }
  end

  defp renew(cell_key, ownership) do
    # The manager's lease rather than the tracked one, so the txid written back is
    # the one this node has shipped up to.
    lease = Manager.lease(cell_key) || ownership.lease

    if lease.etag == ownership.lease.etag do
      store = Manager.store(cell_key)
      {lease.etag, Lease.renew(store, lease, ttl_ms: ownership.ttl_ms)}
    else
      :replaced
    end
  end

  defp record(held, cell_key, {from_etag, {:ok, renewed}}) do
    case Manager.renewed(cell_key, from_etag, renewed) do
      :ok -> Map.put(held, cell_key, tracked(nil, Manager.lease(cell_key) || renewed))
      {:error, :stale} -> Map.delete(held, cell_key)
    end
  end

  # The lease was replaced by a claim on this node between the tick and the renewal.
  defp record(held, cell_key, :replaced), do: Map.delete(held, cell_key)

  defp record(held, cell_key, {_from_etag, {:error, {:held_by, other}}}) do
    if other == Manager.owner() do
      Map.delete(held, cell_key)
    else
      fence(held, cell_key, "held by #{other}")
    end
  end

  defp record(held, cell_key, {_from_etag, {:error, :precondition_failed}}),
    do: fence(held, cell_key, "released or taken by another owner")

  defp record(held, cell_key, {_from_etag, {:error, reason}}) do
    Logger.warning(
      "could not renew the lease on cell #{inspect(cell_key)}: #{inspect(reason)}, " <>
        "#{Ownership.remaining_ms(held[cell_key])}ms left"
    )

    held
  end

  defp fence(held, cell_key, why) do
    Logger.error("lost the lease on cell #{inspect(cell_key)} (#{why}); fencing it")
    Manager.fence(cell_key)
    Map.delete(held, cell_key)
  end

  defp tick_ms(leases) when map_size(leases) == 0, do: @idle_tick_ms

  defp tick_ms(leases) do
    leases
    |> Enum.map(fn {_cell_key, lease} -> div(lease.ttl_ms || Lease.default_ttl_ms(), 15) end)
    |> Enum.min()
    |> max(@min_tick_ms)
    |> min(@max_tick_ms)
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)
end
