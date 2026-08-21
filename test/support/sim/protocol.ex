defmodule AshCell.Sim.Protocol do
  @moduledoc """
  The coordination protocol as pure decisions over a world.

  `variant` selects a deliberately broken implementation. That is not a test
  affordance; it is how we find out whether the invariants can detect anything at
  all. An invariant suite that has never caught a mutant is indistinguishable
  from one that cannot.

  ## This models what production does, which is not what it used to model

  The first version of this file acknowledged a write only after a conditional
  durability write succeeded, and invariant #2 — "anything acknowledged is
  recoverable from the store" — held trivially. That was a simulation of a system
  we had not built. The real one acknowledges on local fsync and ships separately,
  so writing and shipping are two steps here, and the gap between them is where the
  interesting behaviour lives.

  Restating it that way is what turned invariant #2 from a tautology into three
  distinct claims, one of which production does not satisfy. See
  `AshCell.Sim.Invariants`.
  """

  alias AshCell.Sim.{Invariants, Store, World}

  @doc "Node `id` attempts to claim `cell`. Ownership is one conditional write."
  def claim(world, id, cell, variant \\ :correct) do
    node = World.node(world, id)

    # Generation comes from a counter that outlives the lease, not from the lease
    # body and not from counting snapshots.
    #
    # Stage 0 found this and the real code had the same bug: releasing a lease
    # deletes it, so a generation derived from it restarts at 1 and two successive
    # owners get the same number. A generation that repeats is a fence that does
    # not fence.
    generation = next_generation(world, cell)

    case Store.put(world.store, lease_key(cell), {id, generation}, if_none_match: true) do
      {{:ok, _etag}, store} ->
        store = bump_generation(store, cell, generation)

        node = %{
          node
          | held: Map.put(node.held, cell, generation),
            won: [{cell, generation} | node.won],
            local_generation: Map.put(node.local_generation, cell, generation),
            # Adopting a cell means restoring it and learning where its log has got
            # to. A fenced writer does not, which is precisely why its next
            # shipment collides.
            shipped_txid: Map.put(node.shipped_txid, cell, highest_txid(world, cell)),
            values: Map.put(node.values, cell, recoverable(world, cell)),
            fenced: Map.delete(node.fenced, cell)
        }

        world |> Map.put(:store, store) |> World.put_node(node)

      {{:error, :precondition_failed}, store} when variant == :ignore_lease_refusal ->
        # Mutant: treats a refused claim as success. Two nodes then believe they
        # own the same cell at the same generation.
        node = %{
          node
          | held: Map.put(node.held, cell, generation),
            local_generation: Map.put(node.local_generation, cell, generation)
        }

        world |> Map.put(:store, store) |> World.put_node(node)

      {{:error, _}, store} ->
        Map.put(world, :store, store)
    end
  end

  @doc """
  Node `id` writes to `cell` and acknowledges the caller.

  **Acknowledged on local fsync**, with nothing sent to the store. This is what
  production does and it is the whole reason the durability story is a bounded loss
  rather than none: between here and the next `ship/4` the write exists on one
  disk.

  A node that has *learned* it is fenced must refuse rather than acknowledge. That
  is the one thing this step is strict about, because a node still answering callers
  for a cell it knows it does not own is manufacturing writes that are already lost.
  """
  def write(world, id, cell, value, variant \\ :correct) do
    node = World.node(world, id)

    cond do
      not Map.has_key?(node.local_generation, cell) ->
        world

      # Mutant: keeps serving after a refused shipment told it the truth. This is
      # the shape of the real gap -- see the moduledoc of
      # `Invariants.fenced_node_stops_acknowledging/1`.
      Map.get(node.fenced, cell) && variant != :keeps_serving_when_fenced ->
        world

      true ->
        values = Map.update(node.values, cell, MapSet.new([value]), &MapSet.put(&1, value))

        world
        |> World.put_node(%{node | values: values})
        |> World.ack(id, cell, value)
    end
  end

  @doc """
  Node `id` ships `cell` to the store: claim the next txid, put the whole database.

  Keyed by txid from a namespace every owner shares, so two owners compute the same
  next number, one wins, and the loser learns it has been fenced. Keyed by
  generation this never collided at all, because a successor always takes a new
  generation and therefore writes a key its predecessor never touches.
  """
  def ship(world, id, cell, variant \\ :correct) do
    node = World.node(world, id)

    if not Map.has_key?(node.local_generation, cell) do
      world
    else
      # Mutant: reads the high-water mark from the store instead of trusting the
      # local counter -- the "optimisation" that looks like it cannot hurt. It
      # hands a displaced node a txid nobody has taken, so its conditional write
      # succeeds, and because snapshots are whole files it publishes an older
      # database over a newer one. This is what `AshCell.Replicator`'s moduledoc
      # means by "the fence works precisely because a fenced writer's counter is
      # stale".
      txid =
        case variant do
          :reread_high_water -> highest_txid(world, cell) + 1
          _ -> Map.get(node.shipped_txid, cell, 0) + 1
        end

      contents = Map.get(node.values, cell, MapSet.new())

      case Store.put(world.store, Invariants.snapshot_key(cell, txid), contents,
             if_none_match: true
           ) do
        {{:ok, _etag}, store} ->
          node = %{node | shipped_txid: Map.put(node.shipped_txid, cell, txid)}
          world |> Map.put(:store, store) |> World.put_node(node)

        {{:error, :precondition_failed}, store} ->
          # Fenced, and discovered at the only moment that offers a signal at all.
          # Recording it is what lets a later `write/5` refuse.
          node =
            if variant == :ignore_fence,
              do: node,
              else: %{node | fenced: Map.put(node.fenced, cell, true)}

          world |> Map.put(:store, store) |> World.put_node(node)

        {{:error, _}, store} ->
          Map.put(world, :store, store)
      end
    end
  end

  @doc """
  Node `id` drains `cell`: ship, then release.

  Order is the whole point. `:release_before_ship` inverts it.
  """
  def drain(world, id, cell, variant \\ :correct) do
    case variant do
      :release_before_ship ->
        world |> release(id, cell) |> ship(id, cell) |> World.drained(id, cell)

      _ ->
        world |> ship(id, cell) |> then(&release_if_shipped(&1, id, cell))
    end
  end

  @doc """
  The lease's TTL elapses, making `cell` claimable again.

  An explicit step because the simulation has no clock. A crash does not release a
  lease -- that is the whole cost of a node dying rather than draining, and the
  handoff tests measure it against a real bucket -- so a successor cannot claim
  until this happens.
  """
  def expire_lease(world, cell) do
    {_, store} = Store.delete(world.store, lease_key(cell))
    Map.put(world, :store, store)
  end

  @doc false
  def ship_step(world, id, cell), do: ship(world, id, cell)

  @doc false
  def release_step(world, id, cell), do: release(world, id, cell)

  # The lease is deliberately kept when the shipment failed. Releasing after a
  # failed ship invites a successor to claim the cell and resume from an older
  # snapshot while the newest values are still only on this disk.
  defp release_if_shipped(world, id, cell) do
    node = World.node(world, id)

    if Map.get(node.fenced, cell) do
      world
    else
      world |> release(id, cell) |> World.drained(id, cell)
    end
  end

  defp release(world, id, cell) do
    node = World.node(world, id)
    {_, store} = Store.delete(world.store, lease_key(cell))

    world
    |> Map.put(:store, store)
    |> World.put_node(%{node | held: Map.delete(node.held, cell)})
  end

  @doc """
  Node `id` loses everything it had not shipped.

  The hard kill. Local values go with it; the store keeps whatever was shipped.
  """
  def crash(world, id) do
    node = World.node(world, id)

    World.put_node(world, %{
      node
      | held: %{},
        won: [],
        local_generation: %{},
        shipped_txid: %{},
        values: %{},
        fenced: %{}
    })
  end

  @doc "Everything recoverable for `cell`: the contents of its newest snapshot."
  def recoverable(world, cell) do
    case highest_txid(world, cell) do
      0 ->
        MapSet.new()

      txid ->
        case Store.get(world.store, Invariants.snapshot_key(cell, txid)) do
          {{:ok, contents, _etag}, _store} -> contents
          _ -> MapSet.new()
        end
    end
  end

  defp lease_key(cell), do: "cells/#{cell}/lease.json"

  # Monotonic across ownership changes, including changes with no writes between
  # them. Persisted in a counter object so it survives every node forgetting.
  defp next_generation(world, cell) do
    case Store.get(world.store, generation_key(cell)) do
      {{:ok, n, _etag}, _store} -> n + 1
      {{:error, :not_found}, _store} -> 1
    end
  end

  defp bump_generation(store, cell, generation) do
    {_result, store} = Store.put(store, generation_key(cell), generation)
    store
  end

  defp generation_key(cell), do: "cells/#{cell}/generation"

  # One namespace per cell, shared by every owner past and present. Read only when
  # adopting: a writer otherwise uses its own counter, and a stale counter is what
  # makes the conditional write refuse.
  defp highest_txid(world, cell) do
    world.store
    |> Store.list("cells/#{cell}/snapshots/")
    |> Enum.map(&(&1 |> String.split("/") |> List.last() |> String.to_integer()))
    |> Enum.max(fn -> 0 end)
  end
end
