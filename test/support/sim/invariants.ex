defmodule AshCell.Sim.Invariants do
  @moduledoc """
  The specification, expressed as checks.

  These matter more than the simulator does. A simulator with weak invariants
  explores millions of schedules and reports that everything is fine.

  Each returns `:ok` or `{:violation, name, detail}`, and is checked after every
  single step so that a failing history ends one step after the damage rather
  than thousands.

  ## What replaced "nothing acknowledged is ever lost"

  That was the original invariant #2, and it passed for a reason production never
  shared: the simulated protocol acknowledged a write only after a conditional
  durability write succeeded, so the property was true by construction. Once
  `AshCell.Sim.Protocol` was changed to acknowledge on local fsync and ship
  separately — which is what the real system does — the invariant became false, and
  correctly so. Periodic shipping gives a *bounded* loss, not none.

  Deleting it would have been the wrong repair, because it was pointing at
  something. It splits into three claims that are each sharper than the original:

    * `no_shipped_write_lost/1` — durability, once achieved, is not taken away
    * `drain_loses_nothing/1` — the one path that really is lossless
    * `fenced_node_stops_acknowledging/1` — the bound on how wrong a displaced node
      is allowed to be

  The third is the interesting one, and the reason it is stated here is that
  production did not satisfy it when this was written.
  """

  alias AshCell.Sim.{Protocol, Store, World}

  @doc """
  Applies each step in turn, checking every invariant *between* steps.

  Stage 0 found why this matters. Releasing a lease before shipping is a transient
  window: by the time the drain finishes the shipment has happened and the final
  state looks perfectly correct. Checking only at the end reports a clean run on a
  protocol that briefly left a cell claimable with newer data stranded on the
  departing node.

  The bug is the window, so the check has to be able to see windows.
  """
  def run(world, steps) do
    Enum.reduce_while(steps, {:ok, world}, fn step, {:ok, world} ->
      world = step.(world)

      case check_all(world) do
        :ok -> {:cont, {:ok, world}}
        violation -> {:halt, {violation, world}}
      end
    end)
  end

  @doc "Runs every invariant, returning the first violation."
  def check_all(world) do
    Enum.reduce_while(
      [
        &one_writer_per_generation/1,
        &one_current_holder/1,
        &no_shipped_write_lost/1,
        &drain_loses_nothing/1,
        &fenced_node_stops_acknowledging/1,
        &ship_precedes_release/1,
        &monotonic_generations/1
      ],
      :ok,
      fn check, :ok ->
        case check.(world) do
          :ok -> {:cont, :ok}
          violation -> {:halt, violation}
        end
      end
    )
  end

  @doc """
  #1 — A node never holds a generation it did not win.

  Three attempts at stating this, and the mutants forced each correction:

    1. *"no two nodes at the same generation"* — too weak. Once generations come
       from the lease, a node that ignores a refused claim takes the **next**
       generation, so two holders coexist at different generations and nothing
       fires.
    2. *"at most one node holds a cell"* — too strong. A fenced writer that has
       not noticed yet still believes it holds, and that is not a bug; it is the
       precise situation the conditional write exists to make safe.

  What separates the two is not how many nodes believe they hold the cell, but
  whether a belief was **earned**. A stale holder won its generation and has since
  been superseded. A split-brain holder never won one.

  So `held` is a belief and `won` is the record of conditional writes that
  actually succeeded. Beliefs may be stale; they may not be invented.
  """
  def one_writer_per_generation(world) do
    unearned =
      Enum.find_value(world.nodes, fn {id, node} ->
        Enum.find_value(node.held, fn {cell, generation} ->
          if {cell, generation} in node.won, do: nil, else: {id, cell, generation}
        end)
      end)

    case unearned do
      nil -> :ok
      detail -> {:violation, :one_writer_per_generation, detail}
    end
  end

  @doc """
  #1b — At most one node holds the cell at the store's current generation.

  The liveness-facing half: stale believers are tolerated, but exactly one node
  should be current.
  """
  def one_current_holder(world) do
    current =
      for {_id, node} <- world.nodes,
          {cell, generation} <- node.held,
          generation == store_generation(world, cell),
          do: cell

    case current -- Enum.uniq(current) do
      [] -> :ok
      [cell | _] -> {:violation, :one_current_holder, cell}
    end
  end

  defp store_generation(world, cell) do
    case Store.get(world.store, "cells/#{cell}/generation") do
      {{:ok, n, _}, _} -> n
      _ -> 0
    end
  end

  @doc """
  #2a — Durability, once achieved, is never taken away.

  Weaker than "nothing acknowledged is lost" and it has to be: an acknowledged
  write lives on one disk until the next shipment, so a crash in that window loses
  it by design. What must never happen is that a value which *did* reach the store
  stops being recoverable.

  That is not hypothetical. Because snapshots are whole files rather than deltas, a
  successor that resumes from an older state and ships writes *backwards* — the
  newest snapshot then holds less than an earlier one did, and the loss is of data
  the store had already accepted. Release-before-ship produces exactly this.
  """
  def no_shipped_write_lost(world) do
    Enum.reduce_while(cells(world), :ok, fn cell, :ok ->
      shipped_ever =
        world.store
        |> Store.list("cells/#{cell}/snapshots/")
        |> Enum.reduce(MapSet.new(), fn key, acc ->
          case Store.get(world.store, key) do
            {{:ok, contents, _}, _} -> MapSet.union(acc, contents)
            _ -> acc
          end
        end)

      missing = MapSet.difference(shipped_ever, Protocol.recoverable(world, cell))

      if MapSet.size(missing) == 0 do
        {:cont, :ok}
      else
        {:halt, {:violation, :no_shipped_write_lost, {cell, MapSet.to_list(missing)}}}
      end
    end)
  end

  @doc """
  #2b — A clean drain loses nothing it acknowledged.

  The one path that genuinely is lossless, and therefore the one worth stating
  absolutely. A node that ships before releasing has put everything it acknowledged
  into the store; if it had not, releasing would hand the cell to a successor that
  resumes from older data.
  """
  def drain_loses_nothing(world) do
    # Scoped to the draining node's own acknowledgements. Stated over *every*
    # acknowledgement for the cell it was wrong, and wrong in a way that looked
    # right: a successor's ordinary unshipped write showed up as the predecessor's
    # drain having lost data. A drain promises to lose nothing *it* accepted.
    Enum.reduce_while(world.drained, :ok, fn {cell, ids}, :ok ->
      recoverable = Protocol.recoverable(world, cell)

      missing =
        ids
        |> Enum.flat_map(&World.acked_values(world, &1, cell))
        |> Enum.reject(&MapSet.member?(recoverable, &1))

      case missing do
        [] -> {:cont, :ok}
        values -> {:halt, {:violation, :drain_loses_nothing, {cell, values}}}
      end
    end)
  end

  @doc """
  #2c — A node that has learned it is fenced stops acknowledging writes.

  The bound on how wrong a displaced node may be, and the invariant this suite
  exists to have found.

  A node can be displaced long before it discovers it, and that is tolerable: the
  conditional write is what makes it safe, and the discovery arrives when a
  shipment is refused. What is *not* tolerable is carrying on afterwards. Every
  write it acknowledges from that point is one it cannot ship, on a cell somebody
  else owns, and its caller has been told it succeeded.

  This is weaker than "a fenced writer never acknowledges", which was true of the
  old simulated protocol only because that protocol shipped on every write. With a
  local acknowledgement there is no way to know at write time, so the honest
  property is about what happens after the signal, not before it.
  """
  def fenced_node_stops_acknowledging(world) do
    offender =
      Enum.find_value(world.nodes, fn {id, node} ->
        Enum.find_value(node.fenced, fn {cell, true} ->
          unshipped =
            MapSet.difference(
              Map.get(node.values, cell, MapSet.new()),
              Protocol.recoverable(world, cell)
            )

          if MapSet.size(unshipped) > 0, do: {id, cell, MapSet.to_list(unshipped)}
        end)
      end)

    case offender do
      nil -> :ok
      detail -> {:violation, :fenced_node_stops_acknowledging, detail}
    end
  end

  @doc """
  #3 — A lease is never released while local state is newer than the store.

  The drain-ordering bug stated as a property. Releasing first lets a successor
  claim the cell and resume from older data while newer values are still only on
  the departing node.
  """
  def ship_precedes_release(world) do
    Enum.reduce_while(world.nodes, :ok, fn {_id, node}, :ok ->
      stranded =
        Enum.find(node.values, fn {cell, values} ->
          not Map.has_key?(node.held, cell) and
            Map.has_key?(node.local_generation, cell) and
            MapSet.size(MapSet.difference(values, Protocol.recoverable(world, cell))) > 0
        end)

      case stranded do
        nil -> {:cont, :ok}
        {cell, _} -> {:halt, {:violation, :ship_precedes_release, cell}}
      end
    end)
  end

  @doc "#7 — A cell's txid never repeats in the store."
  def monotonic_generations(world) do
    world.store
    |> Store.list("cells/")
    |> Enum.filter(&String.contains?(&1, "/snapshots/"))
    |> Enum.group_by(&cell_of/1, &txid_of/1)
    |> Enum.reduce_while(:ok, fn {cell, txids}, :ok ->
      if txids == Enum.uniq(txids) do
        {:cont, :ok}
      else
        {:halt, {:violation, :monotonic_generations, cell}}
      end
    end)
  end

  def snapshot_key(cell, txid),
    do: "cells/#{cell}/snapshots/#{String.pad_leading(to_string(txid), 9, "0")}"

  defp cells(world) do
    world.store
    |> Store.list("cells/")
    |> Enum.filter(&String.contains?(&1, "/snapshots/"))
    |> Enum.map(&cell_of/1)
    |> Enum.uniq()
  end

  defp cell_of(key), do: key |> String.split("/") |> Enum.at(1)
  defp txid_of(key), do: key |> String.split("/") |> List.last() |> String.to_integer()
end
