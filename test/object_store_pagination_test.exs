defmodule AshCell.ObjectStorePaginationTest do
  @moduledoc """
  S3 and MinIO return at most 1,000 keys per ListObjectsV2 response. A listing that
  stopped at the first page would hand `AshCell.Replicator.latest_txid/2` a low
  high-water mark, and fencing rests on that mark (ADR-08).
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  alias AshCell.{ObjectStore, Replicator}

  @moduletag :object_store
  @moduletag timeout: 300_000

  @key_count 1_205

  setup :require_object_store

  test "list/2 returns every key past the first 1,000-key page", %{store: store} do
    prefix = "pagination/#{unique_cell("list")}/"
    keys = for n <- 1..@key_count, do: prefix <> String.pad_leading("#{n}", 5, "0")
    put_all(store, keys)

    assert {:ok, listed} = ObjectStore.list(store, prefix)
    assert Enum.sort(listed) == keys
  end

  test "list/3 with a small :max_keys walks many pages", %{store: store} do
    prefix = "pagination/#{unique_cell("pages")}/"
    keys = for n <- 1..25, do: prefix <> String.pad_leading("#{n}", 3, "0")
    put_all(store, keys)

    assert {:ok, ^keys} = ObjectStore.list(store, prefix, max_keys: 4)
  end

  test "latest_txid/2 sees the highest txid past 1,000 snapshots", %{store: store} do
    cell = unique_cell("many_snapshots")
    put_all(store, for(txid <- 1..@key_count, do: Replicator.snapshot_key(cell, txid)))

    assert {:ok, @key_count} = Replicator.latest_txid(store, cell)
  end

  defp put_all(store, keys) do
    keys
    |> Task.async_stream(&ObjectStore.put(store, &1, "x"), max_concurrency: 32, timeout: 30_000)
    |> Enum.each(fn {:ok, result} -> assert {:ok, _} = result end)
  end
end
