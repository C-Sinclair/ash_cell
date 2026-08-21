defmodule Vcs.Snapshotter do
  @moduledoc """
  Periodic durability for resident repositories.

  Without this, a repository's only snapshot is the one `AshCell.Drain` takes on a clean
  shutdown, so a crashed node loses every push since the last deploy. A forge cannot offer that.

  ## Why the generation is composed, not the lease's

  `AshCell.Replicator.snapshot/3` writes with `If-None-Match`, so a given generation can be
  claimed exactly once — and a lease's generation is stable for the whole time a node owns the
  cell, bumping only on takeover. That is right for the drain, which snapshots once at the end.
  A loop that reused it would succeed on its first tick and get `:precondition_failed` forever
  after.

  So the key is `epoch * @ticks_per_epoch + tick`: still a single increasing integer, which
  `AshCell.Replicator.newest_snapshot/2` requires (it parses the key's basename with
  `String.to_integer/1`, so a composite key like `5-12.db` would not merely sort oddly, it would
  raise). Ordering survives a takeover because a new epoch starts above every key the old one
  could write: epoch 6 begins at 6_000_000, and epoch 5 cannot reach it.

  A successor's snapshots therefore always outrank a fenced predecessor's, which is what
  `restore/2` needs when it asks for `:latest`.

  ## It also owns the lease, because nothing else does

  `AshCell` ships the lease primitives (`AshCell.Lease`, `AshCell.Ownership`) but never claims
  one — that is the application's job, and this POC had skipped it. A snapshot needs an epoch, and
  the epoch *is* the lease generation, so the loop claims a lease for each resident repository
  and renews it every tick.

  Be precise about what that buys: **snapshot fencing, not push exclusion.** A push is not gated
  on holding the lease, so two nodes serving the same repository would both accept writes; what
  cannot happen is both of them persisting under the same generation, which is what keeps a
  restore coherent. Gating writes on ownership is the next step and it belongs on the push path,
  not in a background loop.

  ## What this is not

  It is not RPO=0. A push is acknowledged before it is snapshotted, so a crash loses up to one
  interval of pushes. Making the ack wait on the PUT is a different design with a different cost
  (see the `Path B` note in the workspace overview), and pretending otherwise would be worse
  than stating the window.
  """
  use GenServer

  require Logger

  @default_interval_ms 60_000
  # Room for 999_999 snapshots within one ownership epoch. At the default interval that is
  # nearly two years of uptime before a bump would collide with the next epoch's floor.
  @ticks_per_epoch 1_000_000

  defstruct [:store, :interval_ms, :owner, ticks: %{}, seen: %{}]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs one sweep now and waits for it.

  Exists for tests and for an operator who wants a snapshot before doing something alarming;
  the periodic timer is unaffected.
  """
  def sweep(timeout \\ 30_000), do: GenServer.call(__MODULE__, :sweep, timeout)

  @doc "The composed generation for an epoch and tick. Public so it can be asserted on."
  def generation(epoch, tick) when tick < @ticks_per_epoch,
    do: epoch * @ticks_per_epoch + tick

  @impl true
  def init(opts) do
    state = %__MODULE__{
      store: Keyword.get(opts, :store),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      owner: Keyword.get(opts, :owner, to_string(node()))
    }

    if state.store do
      schedule(state)
      {:ok, state}
    else
      # No bucket configured means local-only, and a loop with nowhere to write is worse than
      # no loop: it would log a failure every interval forever.
      :ignore
    end
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {taken, state} = run(state)

    {:reply, {:ok, taken}, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    {_taken, state} = run(state)
    schedule(state)

    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :sweep, state.interval_ms)

  defp run(state) do
    AshCell.resident_cells()
    |> Enum.reduce({[], state}, fn tenant, {taken, state} ->
      case snapshot(tenant, state) do
        {:ok, generation, state} -> {[{tenant, generation} | taken], state}
        {:skip, state} -> {taken, state}
      end
    end)
  end

  defp snapshot(tenant, state) do
    cond do
      AshCell.Registry.closing?(tenant) ->
        {:skip, state}

      unchanged?(tenant, state) ->
        {:skip, state}

      # No epoch, no snapshot. A tenant this node cannot own must not be written under a
      # generation it invented.
      is_nil(own(tenant, state)) ->
        {:skip, state}

      true ->
        write(tenant, state)
    end
  end

  # Claims a lease, or renews the one already held, and returns the generation to write under.
  #
  # The TTL is a multiple of the interval so a lease cannot lapse between two ticks; a lapsed
  # lease would let another node take over and bump the epoch while this one still serves.
  defp own(tenant, state) do
    ttl_ms = state.interval_ms * 3

    case AshCell.Manager.lease(tenant) do
      nil ->
        claim(tenant, state, ttl_ms)

      lease ->
        renew(tenant, lease, state, ttl_ms)
    end
  end

  defp claim(tenant, state, ttl_ms) do
    case AshCell.Lease.claim(state.store, tenant, state.owner, ttl_ms: ttl_ms) do
      {:ok, lease} ->
        AshCell.Manager.put_lease(tenant, lease)
        lease.generation

      {:error, {:held_by, other}} ->
        Logger.info("not snapshotting #{tenant}: held by #{other}")
        nil

      {:error, reason} ->
        Logger.warning("lease claim for #{tenant} failed: #{inspect(reason)}")
        nil
    end
  end

  defp renew(tenant, lease, state, ttl_ms) do
    case AshCell.Lease.renew(state.store, lease, ttl_ms: ttl_ms) do
      {:ok, renewed} ->
        AshCell.Manager.put_lease(tenant, renewed)
        renewed.generation

      # Renewal is refused when somebody else has taken the lease over, which means this node
      # has been displaced. Re-claiming is not the answer; noticing is.
      {:error, reason} ->
        Logger.warning("lease renewal for #{tenant} failed: #{inspect(reason)}")
        nil
    end
  end

  defp write(tenant, state) do
    epoch = AshCell.Manager.generation(tenant)
    tick = Map.get(state.ticks, tenant, 0) + 1
    generation = generation(epoch, tick)

    case AshCell.Replicator.snapshot(state.store, tenant, generation) do
      {:ok, %{bytes: bytes}} ->
        Logger.debug("snapshotted #{tenant} at generation #{generation} (#{bytes} bytes)")

        {:ok, generation,
         %{
           state
           | ticks: Map.put(state.ticks, tenant, tick),
             seen: Map.put(state.seen, tenant, fingerprint(tenant))
         }}

      # Somebody else owns this generation, which means this node has been fenced and has not
      # noticed. Stop writing for this tenant rather than looping on a key we can never claim.
      {:error, :precondition_failed} ->
        Logger.warning(
          "snapshot of #{tenant} refused at generation #{generation}: fenced by another owner"
        )

        {:skip, %{state | ticks: Map.put(state.ticks, tenant, tick)}}

      {:error, reason} ->
        # One unreachable bucket or one unreadable file must not stop the sweep for every other
        # repository, so this is logged and abandoned until the next tick.
        Logger.warning("snapshot of #{tenant} failed: #{inspect(reason)}")

        {:skip, state}
    end
  end

  # Whole-file snapshots make re-uploading an idle repository genuinely expensive, so skip a
  # tenant whose bytes have not moved. Size and mtime across the database and its WAL, rather
  # than a hash: a hash would read the whole file to decide whether to read the whole file.
  defp unchanged?(tenant, state) do
    case Map.fetch(state.seen, tenant) do
      {:ok, previous} -> previous == fingerprint(tenant)
      :error -> false
    end
  end

  defp fingerprint(tenant) do
    path = AshCell.path_for(tenant)

    for suffix <- ["", "-wal"] do
      case File.stat(path <> suffix, time: :posix) do
        {:ok, %{size: size, mtime: mtime}} -> {size, mtime}
        {:error, reason} -> reason
      end
    end
  end
end
