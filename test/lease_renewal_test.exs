defmodule AshCell.LeaseRenewalTest do
  @moduledoc """
  `AshCell.LeaseRenewer` keeping a node's leases alive, and fencing the node when a
  renewal finds another owner, against a real bucket.

  TTLs are short so a lease would expire several times over inside one test.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store
  @moduletag :capture_log

  alias AshCell.{Lease, Manager, Replicator}
  alias AshCell.Test.BoundPatient

  @ttl_ms 900

  setup :require_object_store

  setup %{store: store} do
    dir = Path.join(System.tmp_dir!(), "ash_cell_renewal_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrations_path: AshCell.TestMigrations.path(:test),
       store: store,
       owner: "node-a",
       snapshot: false}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, cell: unique_cell("renewal")}
  end

  test "a held lease outlives its TTL", %{store: store, cell: cell} do
    {:ok, claimed} = AshCell.claim(cell, ttl_ms: @ttl_ms)

    Process.sleep(@ttl_ms * 3)

    assert {:ok, "node-a"} = Lease.holder(store, cell)
    assert {:error, {:held_by, "node-a"}} = Lease.claim(store, cell, "node-b", ttl_ms: @ttl_ms)
    assert Manager.lease(cell).etag != claimed.etag
    assert cell in AshCell.resident_cells()
  end

  test "renewing keeps the txid that shipping advanced", %{store: store, cell: cell} do
    {:ok, _} = AshCell.claim(cell, ttl_ms: @ttl_ms)
    BoundPatient.create!("First", tenant: cell)
    {:ok, %{txid: 1}} = Replicator.ship(store, cell)

    Process.sleep(@ttl_ms * 2)

    assert Manager.lease(cell).txid == 1
    BoundPatient.create!("Second", tenant: cell)
    assert {:ok, %{txid: 2}} = Replicator.ship(store, cell)
  end

  test "a node whose lease was taken is fenced on its next renewal",
       %{store: store, cell: cell} do
    {:ok, _} = AshCell.claim(cell, ttl_ms: @ttl_ms)

    # Another owner writing over the lease, as a claim after an expiry would.
    {:ok, _body, etag} = AshCell.ObjectStore.get(store, Lease.key(cell))

    taken =
      Jason.encode!(%{
        owner: "node-b",
        expires_at: System.system_time(:millisecond) + 60_000,
        generation: 99,
        txid: 0
      })

    {:ok, _} = AshCell.ObjectStore.put(store, Lease.key(cell), taken, if_match: etag)

    Process.sleep(@ttl_ms * 2)

    assert Manager.quarantined()[cell] == :fenced
    assert Manager.lease(cell) == nil
    refute cell in AshCell.resident_cells()
    assert {:ok, "node-b"} = Lease.holder(store, cell)
  end

  test "draining a renewed cell releases its lease without fencing it",
       %{store: store, cell: cell} do
    # A release outside the renewer can race a renewal: one landing first makes the
    # release's etag stale, and one landing after finds the lease released and
    # fences the cell. The window is a few milliseconds, and fifteen runs with the
    # release moved out of the renewer did not hit it, so this guards the ordinary
    # drain of a renewing cell rather than reproducing that race.
    for _ <- 1..5 do
      {:ok, _} = AshCell.claim(cell, ttl_ms: 300)
      Process.sleep(:rand.uniform(400))

      assert {:ok, _} = AshCell.Drain.drain_cell(cell, store, 1_000)
      assert Manager.quarantined() == %{}
      assert {:ok, nil} = Lease.holder(store, cell)
    end
  end

  describe "Manager.renewed/3" do
    test "keeps a txid committed since the renewal read the lease",
         %{store: store, cell: cell} do
      {:ok, held} = AshCell.claim(cell, ttl_ms: 60_000)
      {:ok, renewed} = Lease.renew(store, held, ttl_ms: 60_000)
      {:ok, 1} = Manager.claim_txid(cell)
      :ok = Manager.committed(cell, 1)

      assert :ok = Manager.renewed(cell, held.etag, renewed)
      assert %Lease{txid: 1, etag: etag, expires_at: expires_at} = Manager.lease(cell)
      assert {etag, expires_at} == {renewed.etag, renewed.expires_at}
    end

    test "records nothing when the held lease has moved on", %{store: store, cell: cell} do
      {:ok, held} = AshCell.claim(cell, ttl_ms: 60_000)
      {:ok, renewed} = Lease.renew(store, held, ttl_ms: 60_000)

      assert {:error, :stale} = Manager.renewed(cell, "not-the-held-etag", renewed)
      assert Manager.lease(cell) == held
    end
  end
end
