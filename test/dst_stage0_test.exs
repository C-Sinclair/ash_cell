defmodule AshCell.DSTStage0Test do
  @moduledoc """
  Stage 0 of `docs/dst.md`: the store model and the invariants, driven by scripted
  sequences rather than a scheduler.

  The point of doing this before any refactor is to find out whether the
  invariants can be stated precisely at all. The second half — running
  deliberately broken protocols and requiring the invariants to catch them — is
  the part that decides whether they are worth having.
  """
  use ExUnit.Case, async: true

  alias AshCell.Sim.{Invariants, Protocol, Store, World}

  defp world(node_ids \\ [:a, :b], faults \\ []) do
    World.new(node_ids, Store.new(faults: faults))
  end

  describe "the store model" do
    test "create-only refuses an existing key" do
      store = Store.new()
      {{:ok, _}, store} = Store.put(store, "k", "first", if_none_match: true)

      assert {{:error, :precondition_failed}, _} =
               Store.put(store, "k", "second", if_none_match: true)
    end

    test "compare-and-swap requires the etag it was given" do
      store = Store.new()
      {{:ok, etag}, store} = Store.put(store, "k", "v1")

      assert {{:error, :precondition_failed}, store} = Store.put(store, "k", "v2", if_match: "stale")
      assert {{:ok, _}, _} = Store.put(store, "k", "v2", if_match: etag)
    end

    test "exactly one of many concurrent claimants wins" do
      # The property the whole design rests on: no quorum, no membership, one
      # atomic write.
      store = Store.new()

      {winners, _store} =
        Enum.reduce(1..12, {[], store}, fn id, {won, store} ->
          case Store.put(store, "lease", id, if_none_match: true) do
            {{:ok, _}, store} -> {[id | won], store}
            {{:error, _}, store} -> {won, store}
          end
        end)

      assert length(winners) == 1
    end
  end

  describe "the correct protocol holds every invariant" do
    test "a single owner writing and draining" do
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.write(:a, "acme", "row-1")
        |> Protocol.drain(:a, "acme")

      assert :ok = Invariants.check_all(w)
    end

    test "a contested claim leaves one owner" do
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.claim(:b, "acme")

      assert :ok = Invariants.check_all(w)
      assert Map.has_key?(World.node(w, :a).held, "acme")
      refute Map.has_key?(World.node(w, :b).held, "acme")
    end

    test "handover after a drain" do
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.write(:a, "acme", "row-1")
        |> Protocol.drain(:a, "acme")
        |> Protocol.claim(:b, "acme")
        |> Protocol.write(:b, "acme", "row-2")

      assert :ok = Invariants.check_all(w)
    end

    test "a fenced writer cannot acknowledge" do
      # :b claims while :a still believes it owns the tenant. :a's durability
      # write must be refused, and :a must not have acked.
      #
      # This is the test that exposed generation-keyed durability as not
      # fencing at all: :a's write to its own generation succeeded happily
      # until the txid namespace was made shared.
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> then(fn w ->
          {_, store} = Store.delete(w.store, "cells/acme/lease.json")
          %{w | store: store}
        end)
        |> Protocol.claim(:b, "acme")
        |> Protocol.write(:b, "acme", "from-b")
        |> Protocol.write(:a, "acme", "from-a-fenced")

      assert :ok = Invariants.check_all(w)
      acked = Map.get(w.acked, "acme", [])
      refute Enum.any?(acked, fn {_gen, value} -> value == "from-a-fenced" end)
    end

    test "a crash mid-flight loses nothing that was acknowledged" do
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.write(:a, "acme", "durable")
        |> Protocol.crash(:a)
        |> Protocol.claim(:b, "acme")

      assert :ok = Invariants.check_all(w)
    end

    test "store faults do not produce a violation, only a failed operation" do
      w =
        world([:a, :b], [:unavailable, :unavailable])
        |> Protocol.claim(:a, "acme")
        |> Protocol.write(:a, "acme", "row-1")

      assert :ok = Invariants.check_all(w)
    end
  end

  describe "the invariants catch deliberately broken protocols" do
    # This is the check that decides whether any of the above is worth running.
    # Each mutant is a bug we have already met, or one we would most fear.

    test "releasing the lease before snapshotting is caught, but only per-step" do
      steps = [
        &Protocol.claim(&1, :a, "acme"),
        fn w -> %{w | nodes: bump_local(w, :a, "acme")} end,
        &Protocol.release_step(&1, :a, "acme"),
        &Protocol.snapshot_step(&1, :a, "acme")
      ]

      assert {{:violation, :snapshot_precedes_release, _}, _w} = Invariants.run(world(), steps)

      # And the finding that justifies per-step checking: the same run looks
      # perfectly healthy if you only inspect the final state, because the
      # snapshot has landed by then. The bug is the window, not the outcome.
      final = Enum.reduce(steps, world(), fn step, w -> step.(w) end)
      assert :ok = Invariants.check_all(final)
    end

    test "acknowledging before the write is durable is caught" do
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.write(:a, "acme", "never-shipped", :ack_before_durable)

      assert {:violation, :no_acknowledged_write_lost, _} = Invariants.check_all(w)
    end

    test "treating a refused claim as success is caught" do
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.claim(:b, "acme", :ignore_lease_refusal)

      assert {:violation, :one_writer_per_generation, _} = Invariants.check_all(w)
    end

    test "every mutant is caught by a distinct invariant" do
      # If two mutants trip the same invariant, one of them is not being tested
      # by anything specific to it.
      violations =
        for {variant, build} <- [
              {:release_before_snapshot,
               fn ->
                 {violation, _w} =
                   Invariants.run(world(), [
                     &Protocol.claim(&1, :a, "acme"),
                     fn w -> %{w | nodes: bump_local(w, :a, "acme")} end,
                     &Protocol.release_step(&1, :a, "acme"),
                     &Protocol.snapshot_step(&1, :a, "acme")
                   ])

                 violation
               end},
              {:ack_before_durable,
               fn ->
                 world()
                 |> Protocol.claim(:a, "acme")
                 |> Protocol.write(:a, "acme", "x", :ack_before_durable)
               end},
              {:ignore_lease_refusal,
               fn ->
                 world()
                 |> Protocol.claim(:a, "acme")
                 |> Protocol.claim(:b, "acme", :ignore_lease_refusal)
               end}
            ] do
          {:violation, name, _} =
            case build.() do
              {:violation, _, _} = violation -> violation
              world -> Invariants.check_all(world)
            end

          {variant, name}
        end

      names = Enum.map(violations, &elem(&1, 1))
      assert length(Enum.uniq(names)) == length(names), "mutants overlap: #{inspect(violations)}"
    end
  end

  # Simulates local writes that have not been snapshotted, which is the state a
  # drain has to protect.
  defp bump_local(world, id, tenant) do
    node = World.node(world, id)
    generation = Map.get(node.local_generation, tenant, 0) + 1
    Map.put(world.nodes, id, %{node | local_generation: Map.put(node.local_generation, tenant, generation)})
  end
end
