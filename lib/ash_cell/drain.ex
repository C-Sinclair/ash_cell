defmodule AshCell.Drain do
  @moduledoc """
  Graceful shutdown: handing cells over instead of dropping them.

  ## The deploy problem

  A shared-database deployment moves no data when it deploys. A cell deployment
  moves *all* of it: every resident tenant is an open SQLite file on a node that
  is about to disappear, and a rolling deploy does that to the whole fleet, twice.

  Killed rather than drained, each cell leaves two problems behind:

    * **A lease nobody released.** The next node cannot claim the tenant until the
      dead node's lease expires. With a 30s TTL, every tenant is unavailable for up
      to 30 seconds *per deploy*, for no reason other than nobody said goodbye.
      This is the expensive one, and it is almost free to fix.
    * **Local writes nobody shipped.** Anything committed since the last snapshot
      exists only on a disk that is going away.

  Draining fixes both, and the second one is why ordering matters.

  ## Order is load-bearing

      quiesce → checkpoint → snapshot → release lease → close

  **Snapshot before release, never after.** Releasing first opens a window where a
  successor claims the tenant and starts writing from the *previous* snapshot while
  this node still holds newer data locally. The successor's writes are legitimate,
  conditional, and fenced correctly — and the local writes are silently lost. No
  error is raised anywhere. Releasing last closes the window: until the lease is
  gone, nobody else can be writing.

  **Checkpoint before snapshot.** In WAL mode a committed row lives in `<db>-wal`
  until a checkpoint folds it in, so copying the `.db` file alone ships a database
  that is missing its most recent writes.

  ## Quiescing, and why it has a deadline

  Queries do not pass through the cell process — they go straight to the repo
  instance — so the cell cannot see them. Draining tracks how many processes are
  bound to each tenant and waits for that to reach zero.

  It waits with a deadline, because a drain that waits forever is a deploy that
  hangs. Past the deadline the cell is taken anyway: an interrupted read is
  recoverable, a hung deploy under an orchestrator's kill timer is how you get a
  `SIGKILL` and lose the snapshot as well. The deadline should sit comfortably
  inside whatever the platform allows before it stops asking politely.

  ## What this does not solve

  Open LiveView websockets still drop. `fly-replay` routes HTTP requests and does
  nothing for a socket that is already established, so clients reconnect and land
  wherever the load balancer sends them. Draining makes that reconnect *fast* —
  the cell is claimable immediately rather than after a TTL — but the disconnect
  itself is not avoided here.
  """
  use GenServer

  require Logger

  @default_grace_ms 15_000
  @default_concurrency 16
  @poll_ms 50

  # Terminating first among the fleet's children means cells are still alive and
  # the manager is still answering when the drain runs.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Keyword.get(opts, :grace_ms, @default_grace_ms) + 5_000
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Drains every resident cell.

  Returns `{:ok, report}`, where the report names what drained, what failed, and
  how long it took. Failures do not abort the sweep — one tenant that cannot
  snapshot must not strand the rest of the fleet holding leases.
  """
  def run(opts \\ []) do
    started = System.monotonic_time(:millisecond)
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)
    store = Keyword.get(opts, :store, AshCell.Manager.store())

    AshCell.Manager.seal()

    cell_keys = AshCell.resident_cells()

    results =
      cell_keys
      |> Task.async_stream(&drain_cell(&1, store, grace_ms),
        max_concurrency: Keyword.get(opts, :concurrency, @default_concurrency),
        timeout: grace_ms + 10_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(cell_keys)
      |> Enum.map(fn
        {{:ok, result}, cell_key} -> {cell_key, result}
        {{:exit, reason}, cell_key} -> {cell_key, {:error, {:drain_timeout, reason}}}
      end)

    {drained, failed} = Enum.split_with(results, &match?({_, {:ok, _}}, &1))

    report = %{
      drained: Enum.map(drained, &elem(&1, 0)),
      failed: Map.new(failed, fn {cell_key, {:error, reason}} -> {cell_key, reason} end),
      duration_ms: System.monotonic_time(:millisecond) - started
    }

    log(report)
    {:ok, report}
  end

  @doc """
  Drains one tenant.

  Exposed for tests and for targeted operational use — moving a single noisy
  tenant off a node without draining everything else.
  """
  def drain_cell(cell_key, store \\ nil, grace_ms \\ @default_grace_ms) do
    warn_holders(cell_key, grace_ms)
    quiesced? = await_quiescence(cell_key, grace_ms)

    with :ok <- checkpoint(cell_key),
         {:ok, snapshot} <- snapshot(cell_key, store),
         :ok <- release_lease(cell_key, store) do
      AshCell.Manager.close(cell_key)
      {:ok, %{quiesced?: quiesced?, snapshot: snapshot}}
    else
      {:error, reason} ->
        # The lease is deliberately *kept* on failure. Releasing it after a failed
        # snapshot would invite a successor to claim the tenant and resume from an
        # older generation, turning a recoverable local problem into lost writes.
        # Better to let the TTL expire while the newest bytes are still on a disk
        # somebody can recover from.
        Logger.error("cell drain failed for #{inspect(cell_key)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Tells long-lived holders to reconnect, before the socket is taken from them.

  A LiveView will not release a cell on its own — it is holding it because a user
  has the page open. Warned first, it can ask the browser to reconnect *while this
  node can still answer*, so the client lands on the new owner deliberately instead
  of discovering the disconnection when the node vanishes.

  Warnings are jittered across the first half of the grace period. Every tab
  reconnecting on the same millisecond is how a rolling deploy turns into a
  thundering herd against a cold node that is also busy rehydrating cells.
  """
  def warn_holders(cell_key, grace_ms) do
    holders = AshCell.Holders.holders(cell_key)
    spread = max(div(grace_ms, 2), 1)

    for {pid, index} <- Enum.with_index(holders) do
      delay = if length(holders) > 1, do: div(index * spread, length(holders)), else: 0
      Process.send_after(pid, {:ash_cell, :drain_imminent, cell_key}, delay)
    end

    length(holders)
  end

  @doc """
  Waits for every process bound to `tenant` to finish, up to `grace_ms`.

  Returns `true` if the cell went quiet, `false` if the deadline won. The caller
  proceeds either way; the flag exists so the report can say honestly whether a
  request was cut off.
  """
  def await_quiescence(cell_key, grace_ms) do
    deadline = System.monotonic_time(:millisecond) + grace_ms
    poll_until_quiet(cell_key, deadline)
  end

  defp poll_until_quiet(cell_key, deadline) do
    cond do
      AshCell.Registry.active_binds(cell_key) == 0 ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "cell #{inspect(cell_key)} still had #{AshCell.Registry.active_binds(cell_key)} " <>
            "bound process(es) at the drain deadline; taking it anyway"
        )

        false

      true ->
        Process.sleep(@poll_ms)
        poll_until_quiet(cell_key, deadline)
    end
  end

  defp checkpoint(cell_key) do
    AshCell.checkpoint(cell_key)
    :ok
  rescue
    e -> {:error, {:checkpoint_failed, e.__struct__}}
  end

  # With no object store configured the cell is a local file and closing it is the
  # whole job; there is nowhere to hand it over to.
  defp snapshot(_cell_key, nil), do: {:ok, :no_store}

  defp snapshot(cell_key, store) do
    case AshCell.Manager.next_txid(cell_key) do
      nil ->
        {:ok, :no_lease}

      txid ->
        with {:ok, result} <- AshCell.Replicator.snapshot(store, cell_key, txid) do
          AshCell.Manager.commit_txid(cell_key, txid)
          {:ok, result}
        end
    end
  end

  defp release_lease(_cell_key, nil), do: :ok

  defp release_lease(cell_key, store) do
    case AshCell.Manager.lease(cell_key) do
      nil -> :ok
      lease -> AshCell.Lease.release(store, lease)
    end
  end

  defp log(%{failed: failed} = report) when map_size(failed) == 0 do
    Logger.info(
      "drained #{length(report.drained)} cell(s) in #{report.duration_ms}ms; leases released"
    )
  end

  defp log(report) do
    Logger.error(
      "drained #{length(report.drained)} cell(s) in #{report.duration_ms}ms, " <>
        "#{map_size(report.failed)} failed and kept their leases: #{inspect(Map.keys(report.failed))}"
    )
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, opts}
  end

  @impl true
  def terminate(_reason, opts) do
    run(opts)
    :ok
  end
end
