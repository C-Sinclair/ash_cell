defmodule AshCell.StoreRouterTest do
  @moduledoc """
  A fleet whose `store:` is an `AshCell.ObjectStore.Router` keeps each cell's snapshots,
  lease, and generation in the bucket its cell key names, and nowhere else.

  Two buckets on one MinIO stand in for two regions. They prove the routing, not the
  geography.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  alias AshCell.{Lease, Replicator}
  alias AshCell.Test.BoundPatient

  @moduletag :object_store
  @moduletag :capture_log

  defmodule Regions do
    @behaviour AshCell.ObjectStore.Router

    @impl true
    def store_for("eu:" <> _), do: eu()
    def store_for("us:" <> _), do: AshCell.ObjectStoreCase.store()
    def store_for(cell_key), do: raise(ArgumentError, "no region for #{inspect(cell_key)}")

    def eu do
      store = AshCell.ObjectStoreCase.store()
      %{store | bucket: System.get_env("ASHCELL_S3_EU_BUCKET", store.bucket <> "-eu")}
    end
  end

  setup :require_object_store

  setup do
    case AshCell.ObjectStore.list(Regions.eu(), "healthcheck/") do
      {:ok, _} -> :ok
      {:error, reason} -> raise "EU bucket unreachable (#{inspect(reason)}); run scripts/minio.sh"
    end

    dir = Path.join(System.tmp_dir!(), "ash_cell_router_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrations_path: AshCell.TestMigrations.path(:test),
       store: Regions,
       snapshot: false}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, eu_cell: "eu:" <> unique_cell("org"), us_cell: "us:" <> unique_cell("org")}
  end

  defp ship(cell_key), do: Replicator.ship(AshCell.Manager.store(cell_key), cell_key)

  defp keys(store, cell_key) do
    {:ok, snapshots} = AshCell.ObjectStore.list(store, Replicator.snapshot_prefix(cell_key))

    present? = fn key -> match?({:ok, _, _}, AshCell.ObjectStore.get(store, key)) end

    %{
      snapshots: length(snapshots),
      lease?: present?.(Lease.key(cell_key)),
      generation?: present?.(Lease.generation_key(cell_key))
    }
  end

  test "each cell's snapshots, lease and generation land only in its own region's bucket",
       %{eu_cell: eu_cell, us_cell: us_cell} do
    for cell <- [eu_cell, us_cell] do
      {:ok, _} = AshCell.claim(cell)
      BoundPatient.create!("row", tenant: cell)
      {:ok, _} = ship(cell)
    end

    us = AshCell.ObjectStoreCase.store()

    assert %{snapshots: 1, lease?: true, generation?: true} = keys(Regions.eu(), eu_cell)
    assert %{snapshots: 0, lease?: false, generation?: false} = keys(us, eu_cell)

    assert %{snapshots: 1, lease?: true, generation?: true} = keys(us, us_cell)
    assert %{snapshots: 0, lease?: false, generation?: false} = keys(Regions.eu(), us_cell)
  end

  test "a cell key the router cannot place fails the claim instead of using a default bucket" do
    assert_raise ArgumentError, ~r/no region/, fn ->
      AshCell.claim("ap:" <> unique_cell("org"))
    end
  end

  test "a statement on a cell key the router cannot place raises in the caller and leaves the manager up" do
    manager = Process.whereis(AshCell.Manager)

    error =
      assert_raise Ash.Error.Unknown, fn ->
        BoundPatient.create!("row", tenant: "ap:" <> unique_cell("org"))
      end

    assert Exception.message(error) =~ "no region"
    assert Process.whereis(AshCell.Manager) == manager
  end

  test "a branch into another region's bucket is refused", %{eu_cell: eu_cell} do
    {:ok, _} = AshCell.claim(eu_cell)
    {:ok, _} = ship(eu_cell)

    assert {:error, :cross_store_branch} =
             AshCell.fork(eu_cell, to: "us:" <> unique_cell("branch"))
  end
end
