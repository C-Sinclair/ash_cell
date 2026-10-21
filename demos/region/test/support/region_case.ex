defmodule Region.RegionCase do
  @moduledoc """
  Runs a test against both region buckets on a real MinIO, and raises if either is
  unreachable rather than skipping.
  """
  use ExUnit.CaseTemplate

  alias AshCell.{Lease, ObjectStore, Replicator}

  using do
    quote do
      import Region.RegionCase
    end
  end

  setup_all do
    for region <- Region.Stores.regions() do
      store = Region.Stores.store_for(region <> ":healthcheck")

      case ObjectStore.list(store, "healthcheck/") do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          raise "bucket #{store.bucket} unreachable at #{store.endpoint} (#{inspect(reason)}); run ash_cell/scripts/minio.sh"
      end
    end

    :ok
  end

  @doc """
  An organisation name no earlier or later run can collide with.

  Wall-clock time, because the buckets outlive the VM and a counter alone restarts
  each run.
  """
  def unique_name(prefix),
    do: "#{prefix}_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"

  def ship(cell_key), do: Replicator.ship(AshCell.Manager.store(cell_key), cell_key)

  @doc "What one bucket holds for one cell key: snapshot count, lease, and generation."
  def held(region, cell_key) do
    store = Region.Stores.store(bucket(region))
    {:ok, snapshots} = ObjectStore.list(store, Replicator.snapshot_prefix(cell_key))
    present? = fn key -> match?({:ok, _, _}, ObjectStore.get(store, key)) end

    %{
      snapshots: length(snapshots),
      lease?: present?.(Lease.key(cell_key)),
      generation?: present?.(Lease.generation_key(cell_key))
    }
  end

  @doc "Every object key in `region`'s bucket under any cell whose key starts with `key_prefix`."
  def objects_under(region, key_prefix) do
    store = Region.Stores.store(bucket(region))
    {:ok, keys} = ObjectStore.list(store, "cells/" <> AshCell.CellKey.encode(key_prefix))
    keys
  end

  def bucket(region), do: Application.fetch_env!(:region, :object_store)[:buckets][region]
end
