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
      Process.sleep(5)
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
