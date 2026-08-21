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

      assert {{:error, :precondition_failed}, store} =
               Store.put(store, "k", "v2", if_match: "stale")

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

    test "a successor picks up everything its predecessor drained" do
      # The point of shipping before releasing, stated as data rather than ordering.
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.write(:a, "acme", "from-a")
        |> Protocol.drain(:a, "acme")
        |> Protocol.claim(:b, "acme")

      assert :ok = Invariants.check_all(w)
      assert MapSet.member?(World.node(w, :b).values["acme"], "from-a")
    end

    test "a fenced writer's shipment is refused, and it stops serving" do
      # :b takes the cell while :a still believes it holds it. :a acknowledged a
      # write locally -- there is no way for it to know at write time -- so what
      # must happen is that its shipment collides and it serves nothing after.
      #
      # This is the test that exposed generation-keyed durability as not fencing at
      # all: :a's write to its own generation succeeded happily until the txid
      # namespace was made shared.
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.expire_lease("acme")
        |> Protocol.claim(:b, "acme")
        |> Protocol.write(:b, "acme", "from-b")
        |> Protocol.ship(:b, "acme")
        |> Protocol.write(:a, "acme", "from-a-fenced")
        |> Protocol.ship(:a, "acme")

      assert Map.get(World.node(w, :a).fenced, "acme"), ":a should have discovered the fence"

      # And it must not still be answering callers for a cell it knows is not its.
      w = Protocol.write(w, :a, "acme", "from-a-after-fence")
      acked = World.acked_values(w, "acme")

      refute "from-a-after-fence" in acked
      assert "from-b" in acked
    end

    test "a crash loses only what had not been shipped" do
      # Bounded, not zero, and the test says which is which rather than asserting
      # a guarantee the design does not make.
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.write(:a, "acme", "shipped")
        |> Protocol.ship(:a, "acme")
        |> Protocol.write(:a, "acme", "not-shipped")
        |> Protocol.crash(:a)
        # A crash does not release the lease, so the successor waits out the TTL.
        # That delay is the cost of dying rather than draining.
        |> Protocol.expire_lease("acme")
        |> Protocol.claim(:b, "acme")

      assert :ok = Invariants.check_all(w)

      recovered = World.node(w, :b).values["acme"]
      assert MapSet.member?(recovered, "shipped")
      refute MapSet.member?(recovered, "not-shipped")
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

    test "releasing the lease before shipping is caught, but only per-step" do
      steps = [
        &Protocol.claim(&1, :a, "acme"),
        &Protocol.write(&1, :a, "acme", "stranded"),
        &Protocol.release_step(&1, :a, "acme"),
        &Protocol.ship_step(&1, :a, "acme")
      ]

      assert {{:violation, :ship_precedes_release, _}, _w} = Invariants.run(world(), steps)

      # And the finding that justifies per-step checking: the same run looks
      # perfectly healthy if you only inspect the final state, because the
      # shipment has landed by then. The bug is the window, not the outcome.
      final = Enum.reduce(steps, world(), fn step, w -> step.(w) end)
      assert :ok = Invariants.check_all(final)
    end

    test "a stale successor cannot ship backwards while the counter stays local" do
      # Worth stating as a *positive* result, because it is the reason the local
      # counter is not an optimisation. A displaced node holding an older database
      # computes the txid its successor already took, so its shipment is refused
      # before it can publish anything. There is no mutant here to catch: the
      # damage is structurally unreachable.
      steps = [
        &Protocol.claim(&1, :a, "acme"),
        &Protocol.write(&1, :a, "acme", "from-a"),
        &Protocol.ship_step(&1, :a, "acme"),
        fn w -> %{w | nodes: adopt_stale(w, :b, "acme")} end,
        &Protocol.ship_step(&1, :b, "acme")
      ]

      assert {:ok, w} = Invariants.run(world(), steps)
      assert Map.get(World.node(w, :b).fenced, "acme"), ":b should have been refused"
      assert MapSet.member?(Protocol.recoverable(w, "acme"), "from-a")
    end

    test "re-reading the high-water mark before shipping loses shipped data" do
      # And this is why. Consulting the store for the next txid hands a displaced
      # node a number nobody has taken, so its conditional write succeeds -- and
      # because snapshots are whole files it publishes an older database over a
      # newer one. The refusal that protected the previous test never happens.
      steps = [
        &Protocol.claim(&1, :a, "acme"),
        &Protocol.write(&1, :a, "acme", "from-a"),
        &Protocol.ship_step(&1, :a, "acme"),
        fn w -> %{w | nodes: adopt_stale(w, :b, "acme")} end,
        &Protocol.ship(&1, :b, "acme", :reread_high_water)
      ]

      assert {{:violation, :no_shipped_write_lost, {"acme", ["from-a"]}}, _w} =
               Invariants.run(world(), steps)
    end

    test "carrying on after a refused shipment is caught" do
      # The gap this suite was restated to find. A node that has learned it does
      # not own the cell keeps acknowledging writes it can never ship, on a cell
      # somebody else owns.
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.expire_lease("acme")
        |> Protocol.claim(:b, "acme")
        |> Protocol.write(:b, "acme", "from-b")
        |> Protocol.ship(:b, "acme")
        |> Protocol.ship(:a, "acme")
        |> Protocol.write(:a, "acme", "after-fence", :keeps_serving_when_fenced)

      assert {:violation, :fenced_node_stops_acknowledging, _} = Invariants.check_all(w)
    end

    test "a drain that releases without shipping loses acknowledged writes" do
      w =
        world()
        |> Protocol.claim(:a, "acme")
        |> Protocol.write(:a, "acme", "acked-then-dropped")
        |> Protocol.drain(:a, "acme", :release_before_ship)
        |> then(fn w -> %{w | store: elem(Store.delete(w.store, snapshot_of("acme")), 1)} end)

      assert {:violation, :drain_loses_nothing, _} = Invariants.check_all(w)
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
              {:release_before_ship,
               fn ->
                 {violation, _w} =
                   Invariants.run(world(), [
                     &Protocol.claim(&1, :a, "acme"),
                     &Protocol.write(&1, :a, "acme", "stranded"),
                     &Protocol.release_step(&1, :a, "acme"),
                     &Protocol.ship_step(&1, :a, "acme")
                   ])

                 violation
               end},
              {:reread_high_water,
               fn ->
                 {violation, _w} =
                   Invariants.run(world(), [
                     &Protocol.claim(&1, :a, "acme"),
                     &Protocol.write(&1, :a, "acme", "from-a"),
                     &Protocol.ship_step(&1, :a, "acme"),
                     fn w -> %{w | nodes: adopt_stale(w, :b, "acme")} end,
                     &Protocol.ship(&1, :b, "acme", :reread_high_water)
                   ])

                 violation
               end},
              {:keeps_serving_when_fenced,
               fn ->
                 world()
                 |> Protocol.claim(:a, "acme")
                 |> then(fn w ->
                   {_, store} = Store.delete(w.store, "cells/acme/lease.json")
                   %{w | store: store}
                 end)
                 |> Protocol.claim(:b, "acme")
                 |> Protocol.write(:b, "acme", "from-b")
                 |> Protocol.ship(:b, "acme")
                 |> Protocol.ship(:a, "acme")
                 |> Protocol.write(:a, "acme", "x", :keeps_serving_when_fenced)
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

  defp snapshot_of(cell), do: Invariants.snapshot_key(cell, 1)

  # A node that adopted the cell before its predecessor's newest shipment, so it
  # holds an older database than the store does. The state a lease takeover races
  # into, and what makes a backwards shipment possible.
  defp adopt_stale(world, id, cell) do
    node = World.node(world, id)

    Map.put(world.nodes, id, %{
      node
      | local_generation: Map.put(node.local_generation, cell, 99),
        held: Map.put(node.held, cell, 99),
        won: [{cell, 99} | node.won],
        shipped_txid: Map.put(node.shipped_txid, cell, 0),
        values: Map.put(node.values, cell, MapSet.new())
    })
  end
end
