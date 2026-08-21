defmodule AshCell.FencingTest do
  @moduledoc """
  What stops a displaced writer acknowledging a write that is about to be lost.

  The DST simulation (`test/dst_stage0_test.exs`) predicted both bugs these tests
  now guard, and a probe measured both against a real bucket before the fix:

    * generation reset to 1 across a clean handoff, because `Lease.release/2`
      deletes the lease and the next claim found nothing to count from. Two
      successive owners at generation 1 is a fence that does not fence.
    * durability writes keyed by generation never collided, because a successor
      always takes a *new* generation and therefore writes a key its predecessor
      never touches. The fenced write succeeded and returned an etag.

  Written against a real object store rather than a mock. The whole mechanism is
  conditional-write semantics, and a mock would only confirm our own reading of
  them.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store
  @moduletag :capture_log

  alias AshCell.{Lease, Replicator}

  setup :require_object_store

  # Standing in for a node shipping its database, without needing a running fleet.
  # What matters here is which key is claimed and whether the claim is refused.
  defp ship(store, cell_key, txid) do
    AshCell.ObjectStore.put(store, Replicator.snapshot_key(cell_key, txid), "db-at-#{txid}",
      if_none_match: true
    )
  end

  describe "generation allocation" do
    test "does not repeat across a clean handoff", %{store: store} do
      cell = unique_cell("gen_clean")

      {:ok, first} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      Lease.release(store, first)
      {:ok, second} = Lease.claim(store, cell, "node-b", ttl_ms: 60_000)

      assert second.generation > first.generation
    end

    test "does not repeat across an expiry takeover", %{store: store} do
      cell = unique_cell("gen_expiry")

      {:ok, first} = Lease.claim(store, cell, "node-a", ttl_ms: 1)
      Process.sleep(5)
      {:ok, second} = Lease.claim(store, cell, "node-b", ttl_ms: 60_000)

      assert second.generation > first.generation
    end

    test "keeps climbing across many handoffs, including ones with no writes",
         %{store: store} do
      # The case that made deriving generation from the lease body wrong: nobody
      # wrote between these handoffs, so there is nothing but the counter to count.
      cell = unique_cell("gen_many")

      generations =
        for i <- 1..5 do
          {:ok, lease} = Lease.claim(store, cell, "node-#{i}", ttl_ms: 60_000)
          Lease.release(store, lease)
          lease.generation
        end

      assert generations == Enum.sort(generations)
      assert generations == Enum.uniq(generations)
    end

    test "a renewal keeps its generation rather than allocating a new one",
         %{store: store} do
      cell = unique_cell("gen_renew")

      {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      {:ok, renewed} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)

      assert renewed.generation == lease.generation
    end
  end

  describe "adopting a cell" do
    test "learns the txid high-water mark from the store", %{store: store} do
      cell = unique_cell("adopt")

      {:ok, first} = Lease.claim(store, cell, "node-a", ttl_ms: 1)
      assert first.txid == 0, "a cell that has never shipped starts at 0"

      {:ok, _} = ship(store, cell, 1)
      {:ok, _} = ship(store, cell, 2)

      Process.sleep(5)
      {:ok, second} = Lease.claim(store, cell, "node-b", ttl_ms: 60_000)

      assert second.txid == 2
    end

    test "reports 0 for a cell that has never shipped", %{store: store} do
      # Ordinary state for a new cell, so every caller converting an error into 0
      # would be the same code written many times.
      assert {:ok, 0} = Replicator.latest_txid(store, unique_cell("adopt_empty"))
    end

    test "fails the claim when the store cannot be listed", %{store: store} do
      # Never {:ok, 0}. A cell with snapshots whose listing failed would otherwise
      # adopt a mark of 0 and start reclaiming txids that already exist.
      #
      # A missing bucket rather than an unreachable host: same branch, and it
      # answers immediately instead of spending the request's full retry budget.
      # Revoked credentials and a deleted bucket are the realistic versions of
      # this anyway.
      broken = %{store | bucket: "ashcell-no-such-bucket"}
      cell = unique_cell("adopt_unlistable")

      assert {:error, _} = Replicator.latest_txid(broken, cell)
      assert {:error, _} = Lease.claim(broken, cell, "node-a", ttl_ms: 60_000)

      # And nothing was written, so a later claim against a healthy store is clean.
      assert {:ok, %Lease{generation: 1, txid: 0}} =
               Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
    end
  end

  describe "a writer that has lost the cell" do
    test "is refused at the txid its successor already claimed", %{store: store} do
      cell = unique_cell("fenced")

      # node-a takes the cell and ships once. Its local mark is now 1.
      {:ok, a} = Lease.claim(store, cell, "node-a", ttl_ms: 1)
      assert a.txid == 0
      {:ok, _} = ship(store, cell, a.txid + 1)
      a_local_txid = a.txid + 1

      # node-b takes over, learns the mark, and ships.
      Process.sleep(5)
      {:ok, b} = Lease.claim(store, cell, "node-b", ttl_ms: 60_000)
      assert b.txid == 1
      assert {:ok, _} = ship(store, cell, b.txid + 1)

      # node-a has noticed nothing, so its next txid is the one node-b just took.
      # This is the moment the fence has to bite, and it is before node-a has
      # acknowledged anything to a caller.
      assert {:error, :precondition_failed} = ship(store, cell, a_local_txid + 1)
    end

    test "is refused even when it never shipped and its successor did",
         %{store: store} do
      cell = unique_cell("fenced_cold")

      {:ok, a} = Lease.claim(store, cell, "node-a", ttl_ms: 1)
      Process.sleep(5)
      {:ok, b} = Lease.claim(store, cell, "node-b", ttl_ms: 60_000)
      assert {:ok, _} = ship(store, cell, b.txid + 1)

      assert {:error, :precondition_failed} = ship(store, cell, a.txid + 1)
    end

    test "would not be refused if the namespace were keyed by generation",
         %{store: store} do
      # The bug, kept as a test so the reason for the txid namespace cannot be
      # quietly refactored away. Two owners have different generations by
      # construction, so generation-keyed writes never contend.
      cell = unique_cell("why_not_generation")

      {:ok, a} = Lease.claim(store, cell, "node-a", ttl_ms: 1)
      Process.sleep(5)
      {:ok, b} = Lease.claim(store, cell, "node-b", ttl_ms: 60_000)

      refute a.generation == b.generation

      assert {:ok, _} = ship(store, cell, b.generation)
      assert {:ok, _} = ship(store, cell, a.generation)
    end
  end

  describe "the local txid counter" do
    setup %{store: store} do
      dir = Path.join(System.tmp_dir!(), "ash_cell_fencing_#{System.unique_integer([:positive])}")

      start_supervised!(
        {AshCell,
         repo: AshCell.TestRepo,
         dir: dir,
         migrator: AshCell.TestMigrations,
         store: store,
         owner: "node-a"}
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      :ok
    end

    test "advances from the lease, not from the store", %{store: store} do
      # The locality that makes the fence work. If claim_txid/1 consulted the
      # bucket, a displaced node would read its successor's mark and write safely
      # past it -- succeeding, acknowledging, and losing the write later.
      cell = unique_cell("local")

      {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      :ok = AshCell.Manager.put_lease(cell, lease)

      assert {:ok, 1} = AshCell.Manager.claim_txid(cell)
      :ok = AshCell.Manager.abandoned(cell)

      # A successor ships several times. This node must not notice.
      for txid <- 1..3, do: {:ok, _} = ship(store, cell, txid)

      assert {:ok, 1} = AshCell.Manager.claim_txid(cell)
    end

    test "advances only on a committed shipment", %{store: store} do
      cell = unique_cell("commit")

      {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      :ok = AshCell.Manager.put_lease(cell, lease)

      assert {:ok, 1} = AshCell.Manager.claim_txid(cell)
      :ok = AshCell.Manager.committed(cell, 1)
      assert {:ok, 2} = AshCell.Manager.claim_txid(cell)
    end

    test "does not advance for a shipment that was abandoned", %{store: store} do
      # A refused write must leave the mark alone, or the next attempt steps past
      # the successor that fenced it and starts succeeding again.
      cell = unique_cell("abandon")

      {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      :ok = AshCell.Manager.put_lease(cell, lease)

      assert {:ok, 1} = AshCell.Manager.claim_txid(cell)
      :ok = AshCell.Manager.abandoned(cell)
      assert {:ok, 1} = AshCell.Manager.claim_txid(cell)
    end

    test "refuses a second concurrent shipment of the same cell", %{store: store} do
      # Two callers handed the same txid would have one refused, and that refusal
      # is indistinguishable from being fenced by another node. A local overlap
      # must not read as "this node has lost the cell".
      cell = unique_cell("overlap")

      {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      :ok = AshCell.Manager.put_lease(cell, lease)

      assert {:ok, 1} = AshCell.Manager.claim_txid(cell)
      assert {:error, :ship_in_flight} = AshCell.Manager.claim_txid(cell)

      :ok = AshCell.Manager.committed(cell, 1)
      assert {:ok, 2} = AshCell.Manager.claim_txid(cell)
    end

    test "reports no lease for a cell this node does not hold" do
      # A fleet with no object store never takes a lease, which is not an error.
      assert {:error, :no_lease} = AshCell.Manager.claim_txid(unique_cell("unheld"))
    end
  end

  describe "a node that discovers it has been fenced" do
    setup %{store: store} do
      dir = Path.join(System.tmp_dir!(), "ash_cell_fenced_#{System.unique_integer([:positive])}")

      start_supervised!(
        {AshCell,
         repo: AshCell.TestRepo,
         dir: dir,
         migrator: AshCell.TestMigrations,
         store: store,
         owner: "node-a",
         snapshot: false}
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      :ok
    end

    test "stops serving the cell rather than answering from a stale copy",
         %{store: store} do
      # The invariant the simulation states as `fenced_node_stops_acknowledging`.
      # Being displaced without knowing is safe -- the conditional write is what
      # makes it safe. Carrying on *after* the refusal is not: every read is stale
      # and every write can never be shipped.
      cell = unique_cell("fenced_stops")

      {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      :ok = AshCell.Manager.put_lease(cell, lease)

      AshCell.with_tenant(cell, fn ->
        AshCell.Test.TenantPatient.create!("Before", tenant: cell)
      end)

      # A successor takes the txid this node was going to use.
      {:ok, _} = ship(store, cell, lease.txid + 1)

      assert {:error, :precondition_failed} = Replicator.ship(store, cell)

      # Refused, not merely logged: the cell is gone and will not come back on its
      # own, because reactivating would open the same stale file.
      assert {:error, {:quarantined, :fenced}} = AshCell.bind_cell(cell)
      refute cell in AshCell.resident_cells()
    end

    test "gives up the lease, so it cannot renew ownership it does not have",
         %{store: store} do
      cell = unique_cell("fenced_lease")

      {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      :ok = AshCell.Manager.put_lease(cell, lease)
      AshCell.with_tenant(cell, fn -> :ok end)

      {:ok, _} = ship(store, cell, lease.txid + 1)
      assert {:error, :precondition_failed} = Replicator.ship(store, cell)

      assert AshCell.Manager.lease(cell) == nil
      assert {:error, :no_lease} = AshCell.Manager.claim_txid(cell)
    end

    test "can be brought back deliberately, but only deliberately", %{store: store} do
      # Recovery is re-adoption, not a retry. Clearing the quarantine is an
      # explicit act so that nothing reactivates a stale cell by accident.
      cell = unique_cell("fenced_recovery")

      {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      :ok = AshCell.Manager.put_lease(cell, lease)
      AshCell.with_tenant(cell, fn -> :ok end)

      {:ok, _} = ship(store, cell, lease.txid + 1)
      assert {:error, :precondition_failed} = Replicator.ship(store, cell)
      assert {:error, {:quarantined, :fenced}} = AshCell.bind_cell(cell)

      # A real recovery restores from the successor's snapshot first; the snapshot
      # here is a synthetic key, so only the deliberate half is exercised.
      # Restoring real bytes is covered in object_store_test.exs.
      :ok = AshCell.Manager.release(cell)

      assert {:ok, _} = AshCell.bind_cell(cell)
      AshCell.unbind()
    end

    test "quarantines only the cell it lost, not the fleet", %{store: store} do
      cell = unique_cell("fenced_one")
      healthy = unique_cell("fenced_other")

      for c <- [cell, healthy] do
        {:ok, lease} = Lease.claim(store, c, "node-a", ttl_ms: 60_000)
        :ok = AshCell.Manager.put_lease(c, lease)
        AshCell.with_tenant(c, fn -> :ok end)
      end

      txid = AshCell.Manager.lease(cell).txid
      {:ok, _} = ship(store, cell, txid + 1)
      assert {:error, :precondition_failed} = Replicator.ship(store, cell)

      assert {:error, {:quarantined, :fenced}} = AshCell.bind_cell(cell)
      assert {:ok, _} = AshCell.bind_cell(healthy)
      AshCell.unbind()
    end
  end
end
