defmodule AshCell.Sim.Protocol do
  @moduledoc """
  The coordination protocol as pure decisions over a world.

  Stage 0 of `docs/dst.md`: enough of the protocol to state the invariants
  against, driven by scripted sequences rather than a scheduler. If the
  invariants cannot be expressed cleanly here, that is a finding about the design
  — and it arrives before any refactor of the real `Manager` and `Drain`.

  `variant` selects a deliberately broken implementation. That is not a test
  affordance; it is how we find out whether the invariants can detect anything at
  all. An invariant suite that has never caught a mutant is indistinguishable
  from one that cannot.
  """

  alias AshCell.Sim.{Invariants, Store, World}

  @doc "Node `id` attempts to claim `tenant`. Ownership is one conditional write."
  def claim(world, id, tenant, variant \\ :correct) do
    node = World.node(world, id)

    # Generation comes from the lease, not from counting snapshots.
    #
    # Stage 0 found this: deriving it from the number of snapshots gives two
    # successive owners the same generation whenever nobody wrote in between, and
    # a generation that repeats is a fence that does not fence. The lease is the
    # only thing that is definitely written on every ownership change, so it is
    # the only correct place to allocate from.
    generation = next_generation(world, tenant)

    case Store.put(world.store, lease_key(tenant), {id, generation}, if_none_match: true) do
      {{:ok, _etag}, store} ->
        store = bump_generation(store, tenant, generation)

        node = %{
          node
          | held: Map.put(node.held, tenant, generation),
            won: [{tenant, generation} | node.won],
            local_generation: Map.put(node.local_generation, tenant, generation),
            # A new owner hydrates, so it knows the high-water mark. A fenced
            # writer does not -- which is precisely why its next write collides.
            local_txid: Map.put(node.local_txid, tenant, highest_txid(world, tenant))
        }

        world |> Map.put(:store, store) |> World.put_node(node)

      {{:error, :precondition_failed}, store} when variant == :ignore_lease_refusal ->
        # Mutant: treats a refused claim as success. Two nodes then believe they
        # own the same tenant at the same generation.
        node = %{
          node
          | held: Map.put(node.held, tenant, generation),
            local_generation: Map.put(node.local_generation, tenant, generation)
        }

        world |> Map.put(:store, store) |> World.put_node(node)

      {{:error, _}, store} ->
        Map.put(world, :store, store)
    end
  end

  @doc """
  Node `id` writes to `tenant` and acknowledges the caller.

  Durability is a conditional write keyed by generation: a fenced writer finds its
  generation already taken and must not ack.
  """
  def write(world, id, tenant, value, variant \\ :correct) do
    node = World.node(world, id)
    generation = Map.get(node.local_generation, tenant)

    cond do
      is_nil(generation) ->
        world

      variant == :ack_before_durable ->
        # Mutant: acknowledges first and ships afterwards. Nothing fails at the
        # time; the loss surfaces later, to a user.
        World.ack(world, tenant, Map.get(node.local_txid, tenant, 0) + 1, value)

      true ->
        # Durability is keyed by a per-tenant transaction number that every owner
        # shares, NOT by the lease generation.
        #
        # Stage 0 found this, and it is the sharpest finding here. Keyed by
        # generation, a fenced writer at generation 1 writes to a key its
        # successor at generation 2 never touches: the write succeeds, the caller
        # is acked, and the data is superseded the moment the successor snapshots.
        # Nothing is refused, so nothing is fenced. Generation-keyed durability
        # fences only against a successor that reuses the same generation, which
        # is exactly what a successor never does.
        #
        # Sharing one txid namespace is what makes the conditional write bite:
        # both owners compute the same next number, one wins, the loser discovers
        # it before acking. This is why celld keys LTX segments by TXID rather
        # than by epoch.
        txid = Map.get(node.local_txid, tenant, 0) + 1
        key = Invariants.snapshot_key(tenant, txid)

        case Store.put(world.store, key, value, if_none_match: true) do
          {{:ok, _etag}, store} ->
            node = %{
              node
              | snapshotted: Map.put(node.snapshotted, tenant, generation),
                local_txid: Map.put(node.local_txid, tenant, txid)
            }

            world
            |> Map.put(:store, store)
            |> World.put_node(node)
            |> World.ack(tenant, txid, value)

          {{:error, :precondition_failed}, store} ->
            # Fenced. Discovered at the only moment that matters: before acking.
            Map.put(world, :store, store)

          {{:error, _}, store} ->
            Map.put(world, :store, store)
        end
    end
  end

  @doc """
  Node `id` drains `tenant`: snapshot, then release.

  Order is the whole point. `:release_before_snapshot` inverts it.
  """
  def drain(world, id, tenant, variant \\ :correct) do
    case variant do
      :release_before_snapshot ->
        world |> release(id, tenant) |> snapshot(id, tenant)

      _ ->
        world |> snapshot(id, tenant) |> release(id, tenant)
    end
  end

  @doc false
  def snapshot_step(world, id, tenant), do: snapshot(world, id, tenant)

  @doc false
  def release_step(world, id, tenant), do: release(world, id, tenant)

  defp snapshot(world, id, tenant) do
    node = World.node(world, id)
    generation = Map.get(node.local_generation, tenant)

    if is_nil(generation) or Map.get(node.snapshotted, tenant, 0) >= generation do
      world
    else
      key = Invariants.snapshot_key(tenant, Map.get(node.local_txid, tenant, 0) + 1)

      case Store.put(world.store, key, "snapshot", if_none_match: true) do
        {{:ok, _}, store} ->
          node = %{
            node
            | snapshotted: Map.put(node.snapshotted, tenant, generation),
              local_txid: Map.put(node.local_txid, tenant, Map.get(node.local_txid, tenant, 0) + 1)
          }
          world |> Map.put(:store, store) |> World.put_node(node)

        {{:error, _}, store} ->
          Map.put(world, :store, store)
      end
    end
  end

  defp release(world, id, tenant) do
    node = World.node(world, id)
    {_, store} = Store.delete(world.store, lease_key(tenant))

    world
    |> Map.put(:store, store)
    |> World.put_node(%{node | held: Map.delete(node.held, tenant)})
  end

  @doc "Node `id` loses everything it had not persisted."
  def crash(world, id) do
    node = World.node(world, id)
    World.put_node(world, %{
      node
      | held: %{},
        won: [],
        local_generation: %{},
        local_txid: %{},
        snapshotted: %{}
    })
  end

  defp lease_key(tenant), do: "cells/#{tenant}/lease.json"

  # Monotonic across ownership changes, including changes with no writes between
  # them. Persisted in a counter object so it survives every node forgetting.
  defp next_generation(world, tenant) do
    case Store.get(world.store, generation_key(tenant)) do
      {{:ok, n, _etag}, _store} -> n + 1
      {{:error, :not_found}, _store} -> 1
    end
  end

  defp bump_generation(store, tenant, generation) do
    {_result, store} = Store.put(store, generation_key(tenant), generation)
    store
  end

  defp generation_key(tenant), do: "cells/#{tenant}/generation"

  # One namespace per tenant, shared by every owner past and present. Read only
  # when adopting a tenant: a writer otherwise uses its own counter, and a stale
  # counter is what makes the conditional write refuse.
  defp highest_txid(world, tenant) do
    world.store
    |> Store.list("cells/#{tenant}/snapshots/")
    |> length()
  end
end
