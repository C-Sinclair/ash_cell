defmodule AshCell.LeaseTest do
  @moduledoc """
  `AshCell.Lease` against a real bucket: what a release may remove, and which txid a
  renewal claim adopts.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store

  alias AshCell.{Lease, Replicator}

  setup :require_object_store

  defp ship(store, cell_key, txid) do
    AshCell.ObjectStore.put(store, Replicator.snapshot_key(cell_key, txid), "db-at-#{txid}",
      if_none_match: true
    )
  end

  describe "release/2" do
    test "a displaced owner's release leaves its successor's lease alone", %{store: store} do
      cell = unique_cell("release_displaced")

      {:ok, first} = Lease.claim(store, cell, "node-a", ttl_ms: 1)
      # Past the TTL on the store's clock, which counts whole seconds.
      Process.sleep(2_100)
      {:ok, _second} = Lease.claim(store, cell, "node-b", ttl_ms: 60_000)

      assert {:error, :precondition_failed} = Lease.release(store, first)
      assert {:ok, "node-b"} = Lease.holder(store, cell)
      assert {:error, {:held_by, "node-b"}} = Lease.claim(store, cell, "node-c", ttl_ms: 60_000)
    end

    test "a holder's release lets the next claim take the cell at once", %{store: store} do
      cell = unique_cell("release_held")

      {:ok, first} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)

      assert :ok = Lease.release(store, first)
      assert {:ok, nil} = Lease.holder(store, cell)
      assert {:ok, %Lease{owner: "node-b"}} = Lease.claim(store, cell, "node-b", ttl_ms: 60_000)
    end
  end

  describe "expiry measured by the store's clock" do
    # A writer's clock an hour behind wrote leases that were expired on arrival, so
    # every other node took the cell at once. DataLite measured a 270s lag on an
    # Android emulator after its host slept.
    @hour_ms 3_600_000

    defp skewed(offset_ms), do: fn -> System.system_time(:millisecond) + offset_ms end

    test "a writer whose clock lags far beyond the TTL holds a live lease", %{store: store} do
      cell = unique_cell("skew_behind")

      {:ok, _} = Lease.claim(store, cell, "node-a", ttl_ms: 30_000, clock: skewed(-@hour_ms))

      assert {:ok, "node-a"} = Lease.holder(store, cell)
      assert {:error, {:held_by, "node-a"}} = Lease.claim(store, cell, "node-b", ttl_ms: 30_000)
    end

    test "a reader whose clock runs far ahead still sees the lease live", %{store: store} do
      cell = unique_cell("skew_reader")

      {:ok, _} = Lease.claim(store, cell, "node-a", ttl_ms: 30_000)

      assert {:ok, "node-a"} = Lease.holder(store, cell, clock: skewed(@hour_ms))

      assert {:error, {:held_by, "node-a"}} =
               Lease.claim(store, cell, "node-b", ttl_ms: 30_000, clock: skewed(@hour_ms))
    end

    test "a writer whose clock runs ahead does not extend its lease", %{store: store} do
      cell = unique_cell("skew_ahead")

      {:ok, _} = Lease.claim(store, cell, "node-a", ttl_ms: 1, clock: skewed(@hour_ms))
      # Both headers have one-second resolution, so a lease is live for up to a
      # second past its TTL.
      Process.sleep(2_100)

      assert {:ok, :expired} = Lease.holder(store, cell)
      assert {:ok, %Lease{owner: "node-b"}} = Lease.claim(store, cell, "node-b", ttl_ms: 30_000)
    end

    test "a lease written with expires_at, before ttl_ms, is read by the reader's clock",
         %{store: store} do
      cell = unique_cell("legacy_lease")
      now = System.system_time(:millisecond)

      legacy = fn expires_at ->
        Jason.encode!(%{owner: "node-a", expires_at: expires_at, generation: 1, txid: 0})
      end

      {:ok, etag} = AshCell.ObjectStore.put(store, Lease.key(cell), legacy.(now + 60_000))
      assert {:ok, "node-a"} = Lease.holder(store, cell)
      assert {:error, {:held_by, "node-a"}} = Lease.claim(store, cell, "node-b", ttl_ms: 30_000)

      {:ok, _} =
        AshCell.ObjectStore.put(store, Lease.key(cell), legacy.(now - 1), if_match: etag)

      assert {:ok, :expired} = Lease.holder(store, cell)
      assert {:ok, %Lease{owner: "node-b"}} = Lease.claim(store, cell, "node-b", ttl_ms: 30_000)
    end
  end

  describe "claim/4 by the owner already holding the lease" do
    test "adopts the store's newest txid, not the one in the lease body", %{store: store} do
      # Shipping never rewrites the lease body, so its txid is the one from the
      # original claim. A renewal that adopted it started the next shipment on a
      # txid this owner had already written, and fenced itself.
      cell = unique_cell("renew_txid")

      {:ok, %Lease{txid: 0}} = Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
      {:ok, _} = ship(store, cell, 1)
      {:ok, _} = ship(store, cell, 2)

      assert {:ok, %Lease{renewed?: true, txid: 2}} =
               Lease.claim(store, cell, "node-a", ttl_ms: 60_000)
    end
  end
end
