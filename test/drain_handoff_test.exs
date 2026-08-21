defmodule AshCell.DrainHandoffTest do
  @moduledoc """
  The deploy problem, proved end to end against a real object store.

  A rolling deploy takes every node away and brings it back. What that costs
  depends entirely on whether the departing node says goodbye:

    * **Killed.** Its leases stay in the bucket until they expire. The next node
      cannot claim the tenant until then, so every tenant is unavailable for up to
      a full TTL, per deploy, for no reason at all.
    * **Drained.** Leases are released as the node leaves, and the successor
      claims immediately.

  These tests use two owner identities against one bucket to stand in for the old
  and new nodes.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store
  @moduletag :capture_log

  alias AshCell.{Lease, Replicator}
  alias AshCell.Test.TenantPatient

  setup :require_object_store

  setup %{store: store} do
    dir = Path.join(System.tmp_dir!(), "ash_cell_handoff_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrator: AshCell.TestMigrations,
       store: store,
       owner: "node-a"}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, store: store, dir: dir, tenant: unique_tenant("handoff")}
  end

  describe "lease handoff" do
    test "a drained node releases its lease, so a successor claims immediately",
         %{store: store, tenant: tenant} do
      # A long TTL makes the point unmissable: without an explicit release the
      # successor would be locked out for a full minute.
      {:ok, lease} = Lease.claim(store, tenant, "node-a", ttl_ms: 60_000)
      AshCell.Manager.put_lease(tenant, lease)
      write(tenant, "Before Deploy")

      # The successor cannot take over while node-a holds the lease.
      assert {:error, {:held_by, "node-a"}} = Lease.claim(store, tenant, "node-b", ttl_ms: 60_000)

      assert {:ok, report} = AshCell.drain(grace_ms: 500)
      assert tenant in report.drained

      # No waiting on the TTL.
      assert {:ok, %Lease{owner: "node-b"}} = Lease.claim(store, tenant, "node-b", ttl_ms: 60_000)
    end

    test "a killed node holds its lease until the TTL expires",
         %{store: store, tenant: tenant} do
      # The behaviour draining exists to avoid, asserted so the contrast is real
      # rather than rhetorical.
      {:ok, _lease} = Lease.claim(store, tenant, "node-a", ttl_ms: 60_000)

      assert {:error, {:held_by, "node-a"}} = Lease.claim(store, tenant, "node-b", ttl_ms: 60_000)
      assert {:ok, "node-a"} = Lease.holder(store, tenant)
    end
  end

  describe "shipping before releasing" do
    test "writes made just before shutdown are in the object store",
         %{store: store, tenant: tenant} do
      {:ok, lease} = Lease.claim(store, tenant, "node-a", ttl_ms: 60_000)
      AshCell.Manager.put_lease(tenant, lease)

      write(tenant, "Written Seconds Before Deploy")

      assert {:ok, _report} = AshCell.drain(grace_ms: 500)

      # Destroy every local trace, exactly as losing the node would.
      for suffix <- ["", "-wal", "-shm"] do
        File.rm(AshCell.path_for(tenant) <> suffix)
      end

      refute File.exists?(AshCell.path_for(tenant))

      assert {:ok, _} = Replicator.restore(store, tenant)
      AshCell.Manager.unseal()

      assert ["Written Seconds Before Deploy"] = read(tenant)
    end

    test "the snapshot is written before the lease is released",
         %{store: store, tenant: tenant} do
      # Ordering is the whole game. Release first and a successor can claim, start
      # from the previous generation, and write over data this node still held
      # locally -- with no error anywhere.
      {:ok, lease} = Lease.claim(store, tenant, "node-a", ttl_ms: 60_000)
      AshCell.Manager.put_lease(tenant, lease)
      write(tenant, "Ordering Matters")

      AshCell.drain(grace_ms: 500)

      # By the time the lease is claimable, the snapshot is already in the bucket,
      # so the successor adopts a mark that is at least as new as what this node
      # shipped.
      assert {:ok, %Lease{txid: adopted}} = Lease.claim(store, tenant, "node-b", ttl_ms: 60_000)
      assert adopted > lease.txid
    end
  end

  describe "when draining fails" do
    test "the lease is kept rather than released", %{store: store, tenant: tenant} do
      {:ok, lease} = Lease.claim(store, tenant, "node-a", ttl_ms: 60_000)
      AshCell.Manager.put_lease(tenant, lease)
      write(tenant, "Row")

      # Occupy this generation's snapshot key so the drain's conditional PUT is
      # refused, simulating a failure to ship.
      {:ok, _} =
        AshCell.ObjectStore.put(
          store,
          Replicator.snapshot_key(tenant, lease.generation),
          "not a database",
          if_none_match: true
        )

      assert {:ok, report} = AshCell.drain(grace_ms: 500)
      assert Map.has_key?(report.failed, tenant)

      # Releasing here would invite a successor to resume from an older
      # generation while the newest bytes are still only on this disk. Holding
      # the lease keeps that window shut until someone looks.
      assert {:error, {:held_by, "node-a"}} = Lease.claim(store, tenant, "node-b", ttl_ms: 60_000)
      assert {:ok, "node-a"} = Lease.holder(store, tenant)
    end

    test "one failing tenant does not strand the rest of the fleet",
         %{store: store, tenant: tenant} do
      healthy = unique_tenant("healthy")

      for t <- [tenant, healthy] do
        {:ok, lease} = Lease.claim(store, t, "node-a", ttl_ms: 60_000)
        AshCell.Manager.put_lease(t, lease)
        write(t, "Row")
      end

      broken = AshCell.Manager.lease(tenant)

      {:ok, _} =
        AshCell.ObjectStore.put(
          store,
          Replicator.snapshot_key(tenant, broken.generation),
          "not a database",
          if_none_match: true
        )

      assert {:ok, report} = AshCell.drain(grace_ms: 500)

      assert Map.has_key?(report.failed, tenant)
      assert healthy in report.drained

      assert {:ok, %Lease{owner: "node-b"}} =
               Lease.claim(store, healthy, "node-b", ttl_ms: 60_000)
    end
  end

  defp unique_tenant(prefix), do: unique_cell(prefix)

  defp write(tenant, name) do
    AshCell.with_tenant(tenant, fn -> TenantPatient.create!(name, tenant: tenant) end)
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
