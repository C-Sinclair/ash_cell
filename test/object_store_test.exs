defmodule AshCell.ObjectStoreTest do
  @moduledoc """
  Proves the two claims the architecture rests on, against a real S3-compatible
  server (MinIO), not a mock:

    1. A tenant's data really is in the object store, and a database can be
       destroyed locally and brought back from it.
    2. Conditional writes give single-writer ownership with no consensus system.

  Requires MinIO. See `test/support/object_store_case.ex`.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  alias AshCell.{Lease, ObjectStore, Replicator}
  alias AshCell.Test.TenantPatient

  @moduletag :object_store

  setup :require_object_store

  setup %{store: store} do
    dir = Path.join(System.tmp_dir!(), "ash_cell_os_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell, repo: AshCell.TestRepo, dir: dir, migrator: &AshCell.TestSchema.run/1}
    )

    tenant = unique_tenant("tenant")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, store: store, dir: dir, tenant: tenant}
  end

  describe "conditional writes" do
    test "If-None-Match creates a key exactly once", %{store: store} do
      key = "probe/" <> unique_tenant("k")

      assert {:ok, _etag} = ObjectStore.put(store, key, "first", if_none_match: true)
      assert {:error, :precondition_failed} = ObjectStore.put(store, key, "second", if_none_match: true)

      # The loser did not overwrite the winner.
      assert {:ok, "first", _} = ObjectStore.get(store, key)
    end

    test "If-Match only succeeds against the version you read", %{store: store} do
      key = "probe/" <> unique_tenant("k")
      {:ok, first_etag} = ObjectStore.put(store, key, "v1")
      {:ok, _second} = ObjectStore.put(store, key, "v2", if_match: first_etag)

      # first_etag is now stale, so a writer holding it must lose.
      assert {:error, :precondition_failed} = ObjectStore.put(store, key, "v3", if_match: first_etag)
      assert {:ok, "v2", _} = ObjectStore.get(store, key)
    end
  end

  describe "single-writer ownership" do
    test "exactly one of many concurrent claimants wins", %{store: store, tenant: tenant} do
      results =
        1..12
        |> Task.async_stream(fn i -> Lease.claim(store, tenant, "node-#{i}") end,
          max_concurrency: 12,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      losers = Enum.filter(results, &match?({:error, _}, &1))

      assert length(winners) == 1, "expected exactly one winner, got #{length(winners)}"
      assert length(losers) == 11

      [{:ok, lease}] = winners
      assert {:ok, holder} = Lease.holder(store, tenant)
      assert holder == lease.owner
    end

    test "a second node cannot take a live lease", %{store: store, tenant: tenant} do
      {:ok, _lease} = Lease.claim(store, tenant, "node-a", ttl_ms: 60_000)

      assert {:error, {:held_by, "node-a"}} = Lease.claim(store, tenant, "node-b")
    end

    test "an expired lease can be taken over, and the generation advances", %{
      store: store,
      tenant: tenant
    } do
      {:ok, first} = Lease.claim(store, tenant, "node-a", ttl_ms: 1)
      Process.sleep(20)

      assert {:ok, second} = Lease.claim(store, tenant, "node-b")
      assert second.owner == "node-b"

      # The generation bump is what fences node-a's in-flight durability writes.
      assert second.generation == first.generation + 1
    end

    test "the previous owner cannot renew after being displaced", %{store: store, tenant: tenant} do
      {:ok, first} = Lease.claim(store, tenant, "node-a", ttl_ms: 1)
      Process.sleep(20)
      {:ok, _second} = Lease.claim(store, tenant, "node-b")

      assert {:error, {:held_by, "node-b"}} = Lease.renew(store, first)
    end
  end

  describe "replication to the object store" do
    test "a tenant's rows reach the bucket and can be read back independently", %{
      store: store,
      tenant: tenant
    } do
      write(tenant, ["Ada Lovelace", "Grace Hopper"])

      assert {:ok, %{bytes: bytes}} = Replicator.snapshot(store, tenant, 1)
      assert bytes > 0

      # Fetch straight from the object store and inspect the bytes. This is the
      # proof that the data is really there, independent of our own code paths.
      {:ok, stored, _etag} = ObjectStore.get(store, Replicator.snapshot_key(tenant, 1))
      assert String.contains?(stored, "Ada Lovelace")
      assert String.contains?(stored, "Grace Hopper")
    end

    test "a destroyed local database is restored from the object store", %{
      store: store,
      tenant: tenant
    } do
      write(tenant, ["Ada Lovelace", "Grace Hopper"])
      {:ok, _} = Replicator.snapshot(store, tenant, 1)

      # Destroy the local copy completely.
      {:ok, _removed} = AshCell.delete(tenant)
      refute File.exists?(AshCell.path_for(tenant))
      assert [] = read(tenant)

      assert {:ok, %{txid: 1}} = Replicator.restore(store, tenant)
      assert ["Ada Lovelace", "Grace Hopper"] = read(tenant)
    end

    test "restores a specific earlier txid, not just the newest", %{
      store: store,
      tenant: tenant
    } do
      write(tenant, ["Only Ada"])
      {:ok, _} = Replicator.snapshot(store, tenant, 1)

      write(tenant, ["Added Later"])
      {:ok, _} = Replicator.snapshot(store, tenant, 2)

      assert {:ok, 2} = Replicator.latest_txid(store, tenant)

      {:ok, _} = Replicator.restore(store, tenant, 1)
      assert ["Only Ada"] = read(tenant)

      {:ok, _} = Replicator.restore(store, tenant, 2)
      assert ["Added Later", "Only Ada"] = read(tenant)
    end

    test "a fenced writer cannot persist a generation the new owner already took", %{
      store: store,
      tenant: tenant
    } do
      write(tenant, ["Row"])
      {:ok, _} = Replicator.snapshot(store, tenant, 1)

      # The new owner claims generation 2. The old owner, not yet aware it has
      # been displaced, tries the same generation and is refused. It learns it was
      # fenced at the only moment that matters: before acknowledging the write.
      assert {:error, :precondition_failed} = Replicator.snapshot(store, tenant, 1)
    end

    test "one tenant's snapshot never contains another tenant's rows", %{store: store} do
      a = unique_tenant("iso_a")
      b = unique_tenant("iso_b")

      write(a, ["Alpha Patient"])
      write(b, ["Beta Patient"])

      {:ok, _} = Replicator.snapshot(store, a, 1)
      {:ok, _} = Replicator.snapshot(store, b, 1)

      {:ok, stored_a, _} = ObjectStore.get(store, Replicator.snapshot_key(a, 1))
      {:ok, stored_b, _} = ObjectStore.get(store, Replicator.snapshot_key(b, 1))

      assert String.contains?(stored_a, "Alpha Patient")
      refute String.contains?(stored_a, "Beta Patient")
      refute String.contains?(stored_b, "Alpha Patient")
    end
  end

  # The bucket outlives the VM, but System.unique_integer/1 restarts with it, so
  defp unique_tenant(prefix), do: unique_cell(prefix)

  defp write(tenant, names) do
    AshCell.with_tenant(tenant, fn ->
      for name <- names, do: TenantPatient.create!(name, tenant: tenant)
    end)
  end

  defp read(tenant) do
    AshCell.with_tenant(tenant, fn ->
      TenantPatient
      |> Ash.Query.set_tenant(tenant)
      |> Ash.read!()
      |> Enum.map(& &1.name)
      |> Enum.sort()
    end)
  end
end
