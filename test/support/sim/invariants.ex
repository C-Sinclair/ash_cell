defmodule AshCell.Sim.Invariants do
  @moduledoc """
  The specification, expressed as checks.

  These matter more than the simulator does. A simulator with weak invariants
  explores millions of schedules and reports that everything is fine.

  Each returns `:ok` or `{:violation, name, detail}`, and is checked after every
  single step so that a failing history ends one step after the damage rather
  than thousands.
  """

  alias AshCell.Sim.{Store, World}

  @doc """
  Applies each step in turn, checking every invariant *between* steps.

  Stage 0 found why this matters. Releasing a lease before snapshotting is a
  transient window: by the time the drain finishes, the snapshot has been taken
  and the final state looks perfectly correct. Checking only at the end reports
  a clean run on a protocol that briefly left a tenant claimable with newer data
  stranded on the departing node.

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
        &no_acknowledged_write_lost/1,
        &snapshot_precedes_release/1,
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
    2. *"at most one node holds a tenant"* — too strong. A fenced writer that has
       not noticed yet still believes it holds, and that is not a bug; it is the
       precise situation the conditional write exists to make safe.

  What separates the two is not how many nodes believe they hold the tenant, but
  whether a belief was **earned**. A stale holder won its generation and has since
  been superseded. A split-brain holder never won one.

  So `held` is a belief and `won` is the record of conditional writes that
  actually succeeded. Beliefs may be stale; they may not be invented.
  """
  def one_writer_per_generation(world) do
    unearned =
      Enum.find_value(world.nodes, fn {id, node} ->
        Enum.find_value(node.held, fn {tenant, generation} ->
          if {tenant, generation} in node.won, do: nil, else: {id, tenant, generation}
        end)
      end)

    case unearned do
      nil -> :ok
      detail -> {:violation, :one_writer_per_generation, detail}
    end
  end

  @doc """
  #1b — At most one node holds the tenant at the store's current generation.

  The liveness-facing half: stale believers are tolerated, but exactly one node
  should be current.
  """
  def one_current_holder(world) do
    current =
      for {_id, node} <- world.nodes,
          {tenant, generation} <- node.held,
          generation == store_generation(world, tenant),
          do: tenant

    case current -- Enum.uniq(current) do
      [] -> :ok
      [tenant | _] -> {:violation, :one_current_holder, tenant}
    end
  end

  defp store_generation(world, tenant) do
    case Store.get(world.store, "cells/#{tenant}/generation") do
      {{:ok, n, _}, _} -> n
      _ -> 0
    end
  end

  @doc """
  #2 — Anything acknowledged to a caller is recoverable from the store.

  Acking before the store confirms is the single most dangerous shortcut available
  in this design, because nothing surfaces at the time and the loss is discovered
  by a user much later.
  """
  def no_acknowledged_write_lost(world) do
    Enum.reduce_while(world.acked, :ok, fn {tenant, entries}, :ok ->
      missing =
        Enum.reject(entries, fn {txid, _value} ->
          match?({{:ok, _, _}, _}, Store.get(world.store, snapshot_key(tenant, txid)))
        end)

      case missing do
        [] -> {:cont, :ok}
        [{gen, _} | _] -> {:halt, {:violation, :no_acknowledged_write_lost, {tenant, gen}}}
      end
    end)
  end

  @doc """
  #3 — A lease is never released while local state is newer than the store.

  This is the drain-ordering bug stated as a property. Releasing first lets a
  successor claim the tenant and resume from an older generation while newer data
  is still only on the departing node -- correctly fenced, and silently lost.
  """
  def snapshot_precedes_release(world) do
    Enum.reduce_while(world.nodes, :ok, fn {_id, node}, :ok ->
      unreleased =
        Enum.find(node.local_generation, fn {tenant, local} ->
          # Still has local state at this generation, no longer holds the lease,
          # and never snapshotted it.
          not Map.has_key?(node.held, tenant) and Map.get(node.snapshotted, tenant, 0) < local
        end)

      case unreleased do
        nil -> {:cont, :ok}
        {tenant, gen} -> {:halt, {:violation, :snapshot_precedes_release, {tenant, gen}}}
      end
    end)
  end

  @doc "#7 — A tenant's generation never goes backwards in the store."
  def monotonic_generations(world) do
    world.store
    |> Store.list("cells/")
    |> Enum.filter(&String.contains?(&1, "/snapshots/"))
    |> Enum.group_by(&tenant_of/1, &generation_of/1)
    |> Enum.reduce_while(:ok, fn {tenant, gens}, :ok ->
      if gens == Enum.uniq(gens) do
        {:cont, :ok}
      else
        {:halt, {:violation, :monotonic_generations, tenant}}
      end
    end)
  end

  def snapshot_key(tenant, generation),
    do: "cells/#{tenant}/snapshots/#{String.pad_leading(to_string(generation), 9, "0")}"

  defp tenant_of(key), do: key |> String.split("/") |> Enum.at(1)
  defp generation_of(key), do: key |> String.split("/") |> List.last() |> String.to_integer()
end
