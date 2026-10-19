defmodule AshCell.ClaimTest do
  @moduledoc """
  `AshCell.claim/2`: when taking a cell restores it from the store, and when it
  keeps the local file.

  The rule is decided by the lease in the store. A claim that takes the lease from
  nobody, or from an expired owner, restores the newest snapshot. A claim that
  renews this node's own lease keeps the local file, which can hold writes made
  since the last shipment, unless there is no local file to keep.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  alias AshCell.{Lease, Replicator}
  alias AshCell.Test.BoundPatient

  @moduletag :object_store

  setup :require_object_store

  setup %{store: store} do
    dir = Path.join(System.tmp_dir!(), "ash_cell_claim_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrator: AshCell.TestMigrations,
       store: store,
       snapshot: false}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, cell: unique_cell("claim")}
  end

  defp names(cell), do: BoundPatient.read!(tenant: cell) |> Enum.map(& &1.name) |> Enum.sort()

  # One row shipped, one written after the shipment and so only on local disk.
  defp shipped_and_unshipped(store, cell) do
    {:ok, _} = AshCell.claim(cell)
    BoundPatient.create!("A shipped", tenant: cell)
    {:ok, _} = Replicator.ship(store, cell)
    BoundPatient.create!("B unshipped", tenant: cell)
  end

  test "claiming a cell that has never shipped starts it empty and records the lease",
       %{cell: cell} do
    assert {:ok, %Lease{renewed?: false} = lease} = AshCell.claim(cell)

    assert AshCell.Manager.lease(cell) == lease
    assert names(cell) == []
  end

  test "reclaiming while the cell is open keeps its unshipped writes", %{store: store, cell: cell} do
    shipped_and_unshipped(store, cell)

    assert {:ok, %Lease{renewed?: true}} = AshCell.claim(cell)
    assert names(cell) == ["A shipped", "B unshipped"]
  end

  test "reclaiming after a close keeps its unshipped writes", %{store: store, cell: cell} do
    # Closing forgets the manager's copy of the lease while the store still holds
    # it for this node. Restoring here replaced the local file with the last
    # shipment, and "B unshipped" was lost.
    shipped_and_unshipped(store, cell)
    :ok = AshCell.close(cell)

    assert {:ok, %Lease{renewed?: true}} = AshCell.claim(cell)
    assert names(cell) == ["A shipped", "B unshipped"]
  end

  test "reclaiming with no local file restores the newest snapshot", %{store: store, cell: cell} do
    # A node back on an empty disk inside its own lease. Opening an empty database
    # here would ship it as the newest snapshot.
    shipped_and_unshipped(store, cell)
    {:ok, _removed} = AshCell.delete(cell)

    assert {:ok, %Lease{renewed?: true}} = AshCell.claim(cell)
    assert names(cell) == ["A shipped"]
  end

  test "taking the lease replaces the local file with the newest snapshot",
       %{store: store, cell: cell} do
    # Once the lease has been released, another node may have owned and shipped the
    # cell, so what is on this node's disk is not the cell any more.
    shipped_and_unshipped(store, cell)
    :ok = Lease.release(store, AshCell.Manager.lease(cell))
    :ok = AshCell.close(cell)

    assert {:ok, %Lease{renewed?: false}} = AshCell.claim(cell)
    assert names(cell) == ["A shipped"]
  end

  test "Lease.claim/4 reports whether it renewed", %{store: store, cell: cell} do
    assert {:ok, %Lease{renewed?: false}} = Lease.claim(store, cell, "node-a")
    assert {:ok, %Lease{renewed?: true}} = Lease.claim(store, cell, "node-a")
    assert {:error, {:held_by, "node-a"}} = Lease.claim(store, cell, "node-b")
  end
end
