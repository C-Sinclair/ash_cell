defmodule AshCell.ReadOnlyTest do
  @moduledoc """
  `AshCell.open_read_only/2`: a node that does not hold a cell's lease restores the
  newest snapshot and serves reads from it, and a write against it fails instead of
  landing in a local copy that never ships.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store
  @moduletag :capture_log

  alias AshCell.Test.BoundPatient

  setup :require_object_store

  setup %{store: store} do
    dir = Path.join(System.tmp_dir!(), "ash_cell_read_only_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrations_path: AshCell.TestMigrations.path(:test),
       store: store,
       snapshot: false}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, cell: unique_cell("read_only")}
  end

  defp names(cell), do: BoundPatient.read!(tenant: cell) |> Enum.map(& &1.name) |> Enum.sort()

  # Another owner's tenure: claimed, written, shipped and released.
  defp shipped_elsewhere(store, cell) do
    {:ok, _} = AshCell.claim(cell)
    BoundPatient.create!("Shipped", tenant: cell)
    {:ok, _} = AshCell.Drain.drain_cell(cell, store, 1_000)
  end

  # Ash wraps the raise in an unknown error and keeps only its message.
  defp read_only_error?(error), do: Exception.message(error) =~ "ReadOnlyCellError"

  test "serves the newest snapshot and refuses an Ash write", %{store: store, cell: cell} do
    shipped_elsewhere(store, cell)

    assert {:ok, %{txid: 1}} = AshCell.open_read_only(cell)
    assert names(cell) == ["Shipped"]

    error = assert_raise Ash.Error.Unknown, fn -> BoundPatient.create!("Stray", tenant: cell) end
    assert read_only_error?(error)
    assert names(cell) == ["Shipped"]
  end

  test "refuses a raw write on the connection too", %{store: store, cell: cell} do
    shipped_elsewhere(store, cell)
    {:ok, _} = AshCell.open_read_only(cell)

    assert_raise Exqlite.Error, ~r/readonly/, fn ->
      AshCell.with_tenant(cell, fn ->
        AshCell.TestRepo.query!("INSERT INTO tenant_patients (id, name) VALUES ('x', 'Raw')")
      end)
    end
  end

  test "stays read-only when the cell is closed and reopened", %{store: store, cell: cell} do
    shipped_elsewhere(store, cell)
    {:ok, _} = AshCell.open_read_only(cell)
    :ok = AshCell.close(cell)

    assert names(cell) == ["Shipped"]
    assert_raise Ash.Error.Unknown, fn -> BoundPatient.create!("Stray", tenant: cell) end
  end

  test "claiming the cell afterwards makes it writable", %{store: store, cell: cell} do
    shipped_elsewhere(store, cell)
    {:ok, _} = AshCell.open_read_only(cell)

    {:ok, _} = AshCell.claim(cell)
    BoundPatient.create!("After Claim", tenant: cell)

    assert names(cell) == ["After Claim", "Shipped"]
  end

  test "is refused while this node holds the lease", %{cell: cell} do
    # Restoring would replace writes this node has not shipped yet.
    {:ok, _} = AshCell.claim(cell)
    BoundPatient.create!("Unshipped", tenant: cell)

    assert {:error, :lease_held} = AshCell.open_read_only(cell)
    assert names(cell) == ["Unshipped"]
  end

  test "a drain closes it without a failure", %{store: store, cell: cell} do
    shipped_elsewhere(store, cell)
    {:ok, _} = AshCell.open_read_only(cell)

    assert {:ok, %{drained: [^cell], failed: failed}} = AshCell.drain(grace_ms: 500)
    assert failed == %{}
  end

  test "reports a cell that has never shipped", %{cell: cell} do
    assert {:error, :not_found} = AshCell.open_read_only(cell)
  end
end
