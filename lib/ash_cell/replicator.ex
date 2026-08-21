defmodule AshCell.Replicator do
  @moduledoc """
  Ships a cell's database to the object store, and brings it back.

  Snapshots are keyed by an increasing generation and written with
  `If-None-Match`, so a generation is claimed exactly once. That is what fences a
  writer that has lost its lease but has not noticed: it goes to persist
  generation N, finds N already written by the new owner, and fails — before it
  has acknowledged anything to a caller.

  ## Snapshots, not LTX

  This ships the whole file rather than page-level LTX segments. It is honest
  about durability (the object store holds a real, restorable database) and it is
  enough to prove the model, but it is not the production shape: cost and latency
  scale with database size rather than with change size. Page-level replication is
  the next step, and it needs either a Litestream sidecar or WAL-frame access that
  `exqlite` does not currently expose.

  ## Checkpoint first

  In WAL mode a committed row lives in `<db>-wal` until a checkpoint folds it in,
  so shipping the `.db` alone would silently omit recent writes. Every snapshot
  checkpoints first.
  """

  require Logger

  def snapshot_prefix(cell_key),
    do: "cells/#{AshCell.CellKey.encode(cell_key)}/snapshots/"

  def snapshot_key(cell_key, generation),
    do: "#{snapshot_prefix(cell_key)}#{pad(generation)}.db"

  @doc """
  Checkpoints the cell's database and writes it to the object store at
  `generation`.

  Returns `{:error, :precondition_failed}` if that generation already exists,
  which is the fencing signal: another owner has taken over and this writer must
  stop rather than continue.
  """
  def snapshot(store, cell_key, generation) do
    :ok = AshCell.checkpoint(cell_key)
    path = AshCell.path_for(cell_key)

    with {:ok, bytes} <- File.read(path),
         {:ok, etag} <-
           AshCell.ObjectStore.put(store, snapshot_key(cell_key, generation), bytes,
             if_none_match: true
           ) do
      {:ok, %{generation: generation, bytes: byte_size(bytes), etag: etag}}
    end
  end

  @doc "The highest generation present in the object store for this cell_key."
  def latest_generation(store, cell_key) do
    case AshCell.ObjectStore.list(store, snapshot_prefix(cell_key)) do
      {:ok, []} ->
        {:error, :not_found}

      {:ok, keys} ->
        generation =
          keys
          |> Enum.map(&(&1 |> Path.basename(".db") |> String.to_integer()))
          |> Enum.max()

        {:ok, generation}

      other ->
        other
    end
  end

  @doc """
  Restores a cell's database from the object store, replacing whatever is on
  local disk.

  Closes the cell first so no connection is holding the old file, and removes the
  WAL sidecars — leaving a stale `-wal` beside a restored `.db` would let SQLite
  apply frames belonging to a different database.
  """
  def restore(store, cell_key, generation \\ :latest) do
    with {:ok, generation} <- resolve_generation(store, cell_key, generation),
         {:ok, bytes, _etag} <-
           AshCell.ObjectStore.get(store, snapshot_key(cell_key, generation)) do
      AshCell.close(cell_key)
      path = AshCell.path_for(cell_key)

      for suffix <- ["-wal", "-shm"], do: File.rm(path <> suffix)

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)

      {:ok, %{generation: generation, bytes: byte_size(bytes)}}
    end
  end

  defp resolve_generation(store, cell_key, :latest), do: latest_generation(store, cell_key)
  defp resolve_generation(_store, _cell_key, generation), do: {:ok, generation}

  defp pad(generation), do: generation |> Integer.to_string() |> String.pad_leading(9, "0")
end
