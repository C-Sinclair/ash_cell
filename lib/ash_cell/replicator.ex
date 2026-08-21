defmodule AshCell.Replicator do
  @moduledoc """
  Ships a cell's database to the object store, and brings it back.

  Snapshots are keyed by an increasing **transaction id** and written with
  `If-None-Match`, so a txid is claimed exactly once. That is what fences a writer
  that has lost its lease but has not noticed: it goes to persist txid N, finds N
  already written by the new owner, and fails — before it has acknowledged
  anything to a caller.

  ## Why txid and not the lease generation

  Keying by generation looked equivalent and fences nothing. The DST simulation
  predicted this and a probe measured it before the change: a displaced writer at
  generation 1 writes the key for generation 1, its successor at generation 2
  writes a *different* key, and they never collide. The conditional write
  succeeds, the caller is acknowledged, and the data is silently superseded the
  moment the successor ships. Generation-keyed durability fences only against a
  successor that reuses the same generation, which is exactly what a successor
  never does.

  One txid namespace per cell, shared by every owner past and present, is what
  makes the conditional write bite: both owners compute the same next number, one
  wins, and the loser finds out before acknowledging. This is why celld keys LTX
  segments by TXID rather than by epoch.

  The high-water mark is read **once**, when a node adopts the cell (see
  `AshCell.Lease.claim/4`), and incremented locally thereafter. Re-reading it
  before each write would defeat the mechanism entirely: a fenced writer would
  read its successor's high-water mark and write safely above it. The fence works
  precisely because a fenced writer's counter is stale.

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

  def snapshot_key(cell_key, txid), do: "#{snapshot_prefix(cell_key)}#{pad(txid)}.db"

  @doc """
  Ships `cell_key` to the store: reserve a txid, snapshot, record the outcome.

  The one path for getting a cell into the bucket, used by the periodic snapshot in
  `AshCell.Cell` and by `AshCell.Drain`. Having two would mean two places to get
  the txid bookkeeping right, and the bookkeeping is the fence.

  Returns `{:ok, :no_lease}` for a fleet that does not replicate and
  `{:ok, :in_flight}` when this cell is already being shipped -- both ordinary, and
  distinct from `{:error, :precondition_failed}`, which means this node has been
  fenced and its snapshot is refused.
  """
  def ship(store, cell_key) do
    case AshCell.Manager.claim_txid(cell_key) do
      {:ok, txid} ->
        finish(store, cell_key, txid)

      {:error, :no_lease} ->
        {:ok, :no_lease}

      {:error, :ship_in_flight} ->
        {:ok, :in_flight}
    end
  end

  defp finish(store, cell_key, txid) do
    case snapshot(store, cell_key, txid) do
      {:ok, result} ->
        AshCell.Manager.committed(cell_key, txid)
        {:ok, result}

      # Refused means another node holds this cell and has already shipped past us.
      # The mark is deliberately not advanced -- the next attempt must collide on
      # the same txid rather than step over the successor that fenced us -- and the
      # cell stops being served, because from here on every read is stale and every
      # write is unshippable.
      {:error, :precondition_failed} ->
        AshCell.Manager.fence(cell_key)
        {:error, :precondition_failed}

      {:error, reason} ->
        AshCell.Manager.abandoned(cell_key)
        {:error, reason}
    end
  rescue
    # The reservation must be released even when the snapshot raises, or the cell
    # is never shipped again and the failure is a silent one.
    e ->
      AshCell.Manager.abandoned(cell_key)
      reraise e, __STACKTRACE__
  end

  @doc """
  Checkpoints the cell's database and writes it to the object store at `txid`.

  Returns `{:error, :precondition_failed}` if that txid already exists, which is
  the fencing signal: another owner has taken over and this writer must stop
  rather than continue.
  """
  def snapshot(store, cell_key, txid) do
    :ok = AshCell.checkpoint_cell(cell_key)
    path = AshCell.path_for(cell_key)

    with {:ok, bytes} <- File.read(path),
         {:ok, etag} <-
           AshCell.ObjectStore.put(store, snapshot_key(cell_key, txid), bytes,
             if_none_match: true
           ) do
      {:ok, %{txid: txid, bytes: byte_size(bytes), etag: etag}}
    end
  end

  @doc """
  The highest txid in the object store for this cell, or `0` if never shipped.

  Read once, at adoption. `{:ok, 0}` for a cell that has never shipped, because
  that is an ordinary state and every caller would otherwise convert the same error
  into 0 itself.

  A store that cannot be listed is an **error**, never `{:ok, 0}`. Collapsing the
  two would be the worst kind of wrong answer here: a cell with fifty snapshots
  whose listing timed out would adopt a mark of 0 and start reclaiming txids that
  already exist. Those writes are refused, so it is not data loss, but it presents
  as a cell that inexplicably cannot snapshot, long after the transport blip that
  caused it. Failing the claim instead means the cell stays unclaimed and the next
  attempt retries -- unavailability that names its own cause.
  """
  def latest_txid(store, cell_key) do
    with {:ok, txids} <- list_txids(store, cell_key) do
      {:ok, Enum.max(txids, fn -> 0 end)}
    end
  end

  @doc "The highest txid present, or `{:error, :not_found}` if never shipped."
  def newest_snapshot(store, cell_key) do
    with {:ok, txids} <- list_txids(store, cell_key) do
      case txids do
        [] -> {:error, :not_found}
        txids -> {:ok, Enum.max(txids)}
      end
    end
  end

  defp list_txids(store, cell_key) do
    with {:ok, keys} <- AshCell.ObjectStore.list(store, snapshot_prefix(cell_key)) do
      {:ok, Enum.map(keys, &txid_of/1)}
    end
  end

  @doc """
  Restores a cell's database from the object store, replacing whatever is on
  local disk.

  Closes the cell first so no connection is holding the old file, and removes the
  WAL sidecars — leaving a stale `-wal` beside a restored `.db` would let SQLite
  apply frames belonging to a different database.
  """
  def restore(store, cell_key, txid \\ :latest) do
    with {:ok, txid} <- resolve_txid(store, cell_key, txid),
         {:ok, bytes, _etag} <-
           AshCell.ObjectStore.get(store, snapshot_key(cell_key, txid)) do
      # `await_repo?` is load-bearing here, not defensive. A plain close returns while
      # the cell's SQLite connection is still shutting down, and that connection
      # checkpoints the WAL into the `.db` on its way out -- over the bytes written
      # below. The restore then reports success over a database with none of the
      # restored rows in it.
      AshCell.Manager.close(cell_key, await_repo?: true)
      path = AshCell.path_for(cell_key)

      for suffix <- ["-wal", "-shm"], do: File.rm(path <> suffix)

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)

      {:ok, %{txid: txid, bytes: byte_size(bytes)}}
    end
  end

  defp resolve_txid(store, cell_key, :latest), do: newest_snapshot(store, cell_key)
  defp resolve_txid(_store, _cell_key, txid), do: {:ok, txid}

  defp txid_of(key), do: key |> Path.basename(".db") |> String.to_integer()

  defp pad(txid), do: txid |> Integer.to_string() |> String.pad_leading(9, "0")
end
