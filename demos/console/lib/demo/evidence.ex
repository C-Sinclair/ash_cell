defmodule Demo.Evidence do
  @moduledoc """
  The compliance panel's proofs.

  Every function here produces evidence from outside the application's own claims:
  raw bytes off the disk, the standard `sqlite3` CLI's opinion of a file, objects
  fetched back out of the store. The point of the panel is that you do not have to
  take the app's word for anything.
  """

  alias AshCell.{ObjectStore, Replicator}

  @doc "First `bytes` of a clinic's database file, as a hexdump."
  def hexdump(clinic_id, bytes \\ 256) do
    path = AshCell.path_for(clinic_id)

    case File.open(path, [:read, :binary], &IO.binread(&1, bytes)) do
      {:ok, data} when is_binary(data) -> {:ok, format_hex(data)}
      {:ok, :eof} -> {:ok, "(empty file)"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether the file is encrypted, judged the way an auditor would: does the
  standard SQLite library recognise it at all, and does any known plaintext appear
  in the bytes?
  """
  def encryption_report(clinic_id) do
    path = AshCell.path_for(clinic_id)

    case File.read(path) do
      {:ok, bytes} ->
        %{
          path: path,
          size: byte_size(bytes),
          # Every unencrypted SQLite file starts with this 16-byte header.
          sqlite_header?: String.starts_with?(bytes, "SQLite format 3"),
          plaintext_hits: plaintext_hits(bytes),
          key_fingerprint: Demo.Cells.Vault.fingerprint(clinic_id),
          revoked?: Demo.Cells.Vault.revoked?(clinic_id)
        }

      {:error, reason} ->
        %{path: path, error: reason}
    end
  end

  @markers ~w(Lovelace Hopper Turing Dijkstra Liskov Knuth MRN- Storm)

  defp plaintext_hits(bytes) do
    Enum.count(@markers, &String.contains?(bytes, &1))
  end

  @doc """
  Deletes a clinic outright: the cell closes and the bytes leave the filesystem.

  Compare with `DELETE FROM patients WHERE clinic_id = $1` on a shared table,
  which leaves dead tuples until a vacuum and leaves the clinic's rows
  interleaved with everyone else's on the same pages in the meantime.
  """
  def delete_clinic(clinic_id) do
    {:ok, removed} = AshCell.delete(clinic_id)
    {:ok, %{removed: removed, exists_after: File.exists?(AshCell.path_for(clinic_id))}}
  end

  @doc "The whole clinic as one file. Data portability as a copy."
  def export_clinic(clinic_id) do
    :ok = AshCell.checkpoint(clinic_id)
    File.read(AshCell.path_for(clinic_id))
  end

  @doc """
  Ships the clinic to the object store.

  Goes through `Replicator.ship/2` rather than reserving a txid and snapshotting
  separately: the txid bookkeeping *is* the fence, and doing it here as well would
  be a second place to get it wrong. A fleet with no lease, or a ship already in
  flight, is an ordinary answer rather than an error.
  """
  def replicate(clinic_id) do
    Replicator.ship(store(), clinic_id)
  end

  @doc """
  Destroys the local database and brings it back from the object store.

  This is the proof that the object store holds a real, restorable database rather
  than a backup nobody has ever tried to use.
  """
  def destroy_and_restore(clinic_id) do
    store = store()

    with {:ok, txid} <- Replicator.newest_snapshot(store, clinic_id),
         {:ok, _} <- Demo.Evidence.delete_clinic(clinic_id),
         false <- File.exists?(AshCell.path_for(clinic_id)),
         {:ok, restored} <- Replicator.restore(store, clinic_id, txid) do
      {:ok, Map.put(restored, :counts, Demo.Benchmark.count_rows(clinic_id))}
    end
  end

  @doc "Objects held for this clinic, listed straight from the store."
  def stored_objects(clinic_id) do
    case ObjectStore.list(store(), "cells/#{clinic_id}/") do
      {:ok, keys} -> keys
      _ -> []
    end
  end

  @doc "Fetches a stored snapshot back and reports what it actually is."
  def inspect_stored_snapshot(clinic_id) do
    store = store()

    with {:ok, txid} <- Replicator.newest_snapshot(store, clinic_id),
         {:ok, bytes, etag} <- ObjectStore.get(store, Replicator.snapshot_key(clinic_id, txid)) do
      {:ok,
       %{
         txid: txid,
         etag: etag,
         size: byte_size(bytes),
         sqlite_header?: String.starts_with?(bytes, "SQLite format 3"),
         plaintext_hits: plaintext_hits(bytes),
         head: format_hex(binary_part(bytes, 0, min(96, byte_size(bytes))))
       }}
    end
  end

  def store do
    config = Application.get_env(:demo, :object_store)

    ObjectStore.new(
      endpoint: config[:endpoint],
      bucket: config[:bucket],
      access_key_id: config[:access_key_id],
      secret_access_key: config[:secret_access_key]
    )
  end

  defp format_hex(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.chunk_every(16)
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {chunk, index} ->
      offset = index * 16
      hex = Enum.map_join(chunk, " ", &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))

      ascii =
        Enum.map_join(chunk, "", fn byte ->
          if byte in 32..126, do: <<byte>>, else: "."
        end)

      "#{String.pad_leading(Integer.to_string(offset, 16), 8, "0")}  #{String.pad_trailing(hex, 47)}  |#{ascii}|"
    end)
  end
end
