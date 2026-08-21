defmodule AshCell.PeriodicSnapshotTest do
  @moduledoc """
  The gap this closes, proved rather than asserted.

  Before periodic shipping, a cell reached the bucket only when the node drained.
  So a clean shutdown was safe and a hard kill lost *everything written since the
  cell activated* — not a second of writes, the whole session. The first test here
  is that difference, run both ways against a real bucket.

  What this does not claim: RPO=0. An acknowledged write still lives only on local
  disk until the next shipment, and the last test says so out loud so nobody
  mistakes a bounded loss for no loss.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store
  @moduletag :capture_log

  alias AshCell.{Lease, Replicator}
  alias AshCell.Test.TenantPatient

  setup :require_object_store

  defp start_fleet(store, snapshot_opts) do
    dir = Path.join(System.tmp_dir!(), "ash_cell_periodic_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrator: AshCell.TestMigrations,
       store: store,
       owner: "node-a",
       snapshot: snapshot_opts}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write(cell, name) do
    AshCell.with_tenant(cell, fn -> TenantPatient.create!(name, tenant: cell) end)
  end

  # Takes a lease so the cell has somewhere to ship to. Activation does not yet
  # claim leases, so tests do it explicitly.
  defp adopt(store, cell) do
    {:ok, lease} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
    :ok = AshCell.Manager.put_lease(cell, lease)
    lease
  end

  defp await_snapshot(store, cell, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case Replicator.latest_txid(store, cell) do
        {:ok, txid} when txid > 0 -> {:ok, txid}
        _ -> Process.sleep(50) && :pending
      end
    end)
    |> Enum.find_value(fn
      {:ok, txid} -> {:ok, txid}
      :pending -> if System.monotonic_time(:millisecond) > deadline, do: :timeout
    end)
  end

  describe "a hard kill" do
    test "loses everything written since activation when nothing ships periodically",
         %{store: store} do
      # The behaviour before this feature existed, kept as a test so the size of
      # the gap is on record rather than remembered.
      start_fleet(store, false)
      cell = unique_cell("no_periodic")
      adopt(store, cell)

      write(cell, "Never Shipped")
      Process.sleep(300)

      assert {:ok, 0} = Replicator.latest_txid(store, cell),
             "nothing should have reached the bucket without a drain"
    end

    test "loses only what happened since the last shipment when one is scheduled",
         %{store: store} do
      # Same sequence, same absence of a drain. The difference is entirely the
      # periodic shipment.
      start_fleet(store, wal_bytes: 1, max_age_ms: 10, interval_ms: 20)
      cell = unique_cell("with_periodic")
      adopt(store, cell)

      write(cell, "Shipped Without A Drain")

      assert {:ok, txid} = await_snapshot(store, cell)
      assert txid > 0

      # And the shipped copy is a real database, not just bytes at a key.
      {:ok, _} = AshCell.delete(cell)
      assert {:ok, _} = Replicator.restore(store, cell)
      assert ["Shipped Without A Drain"] = names(cell)
    end
  end

  describe "the size trigger" do
    test "stops shipping a cell once nobody is writing to it", %{store: store} do
      # A dormant cell must cost nothing, and this is the test that proves the
      # mechanism rather than the intention.
      #
      # Activation itself writes -- migrations run before the cell is available --
      # so a brand-new cell legitimately has a dirty WAL and ships once. What must
      # not happen is that it keeps shipping. That only holds because the snapshot
      # checkpoints with TRUNCATE: a PASSIVE checkpoint leaves the WAL file at its
      # high-water mark, so an untouched cell would look dirty forever and pay a
      # whole-file PUT on every tick.
      start_fleet(store, wal_bytes: 1, max_age_ms: 1, interval_ms: 20)
      cell = unique_cell("dormant")
      adopt(store, cell)

      AshCell.with_tenant(cell, fn -> :ok end)
      assert {:ok, after_activation} = await_snapshot(store, cell)

      # Many ticks pass with no writes at all.
      Process.sleep(400)

      assert {:ok, ^after_activation} = Replicator.latest_txid(store, cell),
             "a cell nobody wrote to kept shipping"
    end

    test "holds off while the WAL is below the threshold", %{store: store} do
      # A high size threshold and a long max age means no trigger fires.
      start_fleet(store, wal_bytes: 100_000_000, max_age_ms: :timer.minutes(10), interval_ms: 20)
      cell = unique_cell("under_threshold")
      adopt(store, cell)

      write(cell, "Small")
      Process.sleep(300)

      assert {:ok, 0} = Replicator.latest_txid(store, cell)
    end
  end

  describe "the age trigger" do
    test "ships a single small write once it is old enough", %{store: store} do
      # The low-traffic tenant. Size alone would never ship this.
      start_fleet(store, wal_bytes: 100_000_000, max_age_ms: 50, interval_ms: 20)
      cell = unique_cell("aged")
      adopt(store, cell)

      write(cell, "One Small Row")

      assert {:ok, txid} = await_snapshot(store, cell)
      assert txid > 0
    end
  end

  describe "shipping and draining together" do
    test "a drain after periodic shipments continues the same txid sequence",
         %{store: store} do
      # Both paths go through Replicator.ship/2, so the drain must not reuse a txid
      # the timer already claimed -- that would look exactly like being fenced.
      start_fleet(store, wal_bytes: 1, max_age_ms: 10, interval_ms: 20)
      cell = unique_cell("then_drained")
      adopt(store, cell)

      write(cell, "First")
      assert {:ok, shipped} = await_snapshot(store, cell)

      write(cell, "Second")
      assert {:ok, report} = AshCell.drain(grace_ms: 500)

      assert report.failed == %{}
      assert {:ok, after_drain} = Replicator.latest_txid(store, cell)
      assert after_drain > shipped
    end

    test "the periodic path never blocks queries on the cell", %{store: store} do
      # Shipping is a whole-file PUT. Done inside the cell process it would stall
      # every query for that cell for the length of the upload.
      start_fleet(store, wal_bytes: 1, max_age_ms: 10, interval_ms: 20)
      cell = unique_cell("not_blocked")
      adopt(store, cell)

      write(cell, "Row")
      assert {:ok, _} = await_snapshot(store, cell)

      # Reads keep working across many shipment cycles.
      for _ <- 1..20 do
        assert ["Row"] = names(cell)
        Process.sleep(10)
      end
    end
  end

  describe "what this does not promise" do
    test "a write can be acknowledged and not yet be in the bucket", %{store: store} do
      # Said out loud because a bounded RPO is easily mistaken for RPO=0. Closing
      # this needs the acknowledgement itself gated on durability, which is a
      # different design -- see docs/spec.md section 2.
      start_fleet(store, wal_bytes: 100_000_000, max_age_ms: :timer.minutes(10), interval_ms: 20)
      cell = unique_cell("acked_not_durable")
      adopt(store, cell)

      write(cell, "Acknowledged")

      assert ["Acknowledged"] = names(cell), "the caller was told this succeeded"
      assert {:ok, 0} = Replicator.latest_txid(store, cell), "and it is not in the bucket"
    end
  end

  defp names(cell) do
    AshCell.with_tenant(cell, fn ->
      TenantPatient
      |> Ash.Query.set_tenant(cell)
      |> Ash.read!()
      |> Enum.map(& &1.name)
      |> Enum.sort()
    end)
  end
end
