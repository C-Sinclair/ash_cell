defmodule Region.Stores do
  @moduledoc """
  Routes a cell to its region's bucket by the region prefix of its cell key.

  A key whose region is not configured raises rather than falling back to a default
  bucket, because a fallback would put that cell's data in the wrong region with
  nothing raising. See [ADR-30](../../../../docs/decisions/ADR-30-route-the-store-by-cell-key.md).
  """
  @behaviour AshCell.ObjectStore.Router

  @impl true
  def store_for(cell_key) when is_binary(cell_key) do
    [region | _] = String.split(cell_key, ":", parts: 2)

    case Map.fetch(buckets(), region) do
      {:ok, bucket} ->
        store(bucket)

      :error ->
        raise ArgumentError,
              "no bucket for region #{inspect(region)} in cell key #{inspect(cell_key)}"
    end
  end

  @doc "The regions this fleet can place a cell in."
  def regions, do: Map.keys(buckets())

  @doc "The fleet options for `Region.CellRepo`."
  def fleet_config do
    [
      dir: Application.get_env(:ash_cell, :dir, "priv/cells"),
      migrations_path: Application.app_dir(:region, "priv/cell_migrations"),
      store: __MODULE__,
      owner: to_string(node()),
      max_resident: 64,
      snapshot: false
    ]
  end

  def store(bucket) do
    config = config()

    AshCell.ObjectStore.new(
      endpoint: config[:endpoint],
      bucket: bucket,
      access_key_id: config[:access_key_id],
      secret_access_key: config[:secret_access_key]
    )
  end

  defp buckets, do: config()[:buckets]
  defp config, do: Application.fetch_env!(:region, :object_store)
end
