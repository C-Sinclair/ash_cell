defmodule CollabEditor.Editing do
  @moduledoc """
  Everything the editor does to a document.

  ## The protocol

  The browser holds a Yjs document; so, effectively, does the cell. A keystroke
  produces a Yjs update, which the browser pushes here. `append/3` stores it and
  broadcasts it, and every other client applies it. Convergence is Yjs's job:
  updates commute, so two people typing in the same word merge character by
  character and nobody loses a keystroke.

  Awareness — cursors, selections, names — is relayed and **never stored**. It is
  ephemeral state with a lifetime in seconds; putting it in the document's file
  would spend the cell's single connection on cursor moves.

  ## So what is the cell for, if the CRDT is what makes it correct?

  This is the honest question, and it has a specific answer: **the log has to live
  somewhere, and keeping it bounded needs a single writer even though editing does
  not.**

  `compact/1` is `read the whole log; merge it; write the snapshot; delete what was
  merged`. A CRDT does not make that safe. Two nodes compacting one document
  concurrently can each merge a log the other is truncating, and an update that
  lands between one node's read and its delete is silently gone — a corruption a
  CRDT cannot repair, because the update is not anywhere any more.

  Everyone who builds this on shared storage needs a lock, a lease, or a
  designated compactor. A cell *is* that, by construction:

    * one connection per document, so compaction cannot interleave with an append
    * `BEGIN IMMEDIATE`, so the merge-and-truncate takes its write lock up front
    * a lease on the object store, so a second node cannot be compacting the same
      document at all
    * one transaction, so a cell taken mid-compaction aborts rather than leaving a
      truncated log with no snapshot

  The demo's claim is therefore not "the cell orders your edits" — Yjs does not
  need that. It is "**a CRDT gives you convergence; it does not give you a safe
  place to keep the log.**"
  """

  alias CollabEditor.CellKey
  alias CollabEditor.Docs.{Document, Snapshot, Update}

  require Ash.Query

  @pubsub CollabEditor.PubSub
  @snapshot_id "current"

  @doc "PubSub topic for a document. One topic per cell, same as one owner per cell."
  def topic(doc_id), do: "doc:" <> doc_id

  def subscribe(doc_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(doc_id))

  @doc """
  Creates a document, which means creating a cell.

  The cell's schema is applied on first activation, before the document row is
  written — a document that cannot be migrated never exists, rather than existing
  half-formed.
  """
  def create_document(title) do
    doc_id = Ash.UUID.generate()

    Document.create(
      %{id: doc_id, title: title, created_at: DateTime.utc_now() |> DateTime.truncate(:second)},
      tenant: doc_id
    )
  end

  @doc "Renames a document. One row, one cell, no coordination."
  def rename(doc_id, title) do
    with {:ok, document} <- fetch_document(doc_id) do
      Document.update(document, %{title: title}, tenant: doc_id)
    end
  end

  @doc """
  Deletes a document: the file, the log, the history, the key's only referent.

  This is `rm`, not `DELETE FROM`. There are no dead tuples holding the text of a
  document somebody asked you to delete, and no vacuum to schedule.
  """
  def delete_document(doc_id), do: AshCell.delete(CellKey.resolve(doc_id))

  @doc """
  Every document, by opening every cell.

  This is the cost of cutting cells per document, shown rather than hidden: there
  is no shared table to `SELECT` from, so a list is a fan-out. It is fine at demo
  scale and it is a real problem at ten thousand documents, which is what a
  separate index exists to solve. The point of leaving it as a fan-out here is that
  the cost is visible in the code rather than discovered in production.
  """
  def list_documents do
    cell_dir()
    |> File.ls()
    |> case do
      {:ok, files} -> files
      {:error, _} -> []
    end
    |> Enum.filter(&String.ends_with?(&1, ".db"))
    |> Enum.map(&String.replace_suffix(&1, ".db", ""))
    |> Enum.flat_map(fn encoded ->
      with {:ok, cell_key} <- AshCell.CellKey.decode(encoded),
           {:ok, doc_id} <- CellKey.document_id(cell_key),
           {:ok, document} <- fetch_document(doc_id) do
        [document]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  @doc """
  The document's whole state as one Yjs update, plus the sequence number it is
  current as of.

  Read inside one transaction, so a client cannot be handed state from *after* the
  point it is told to resume from — which would make it skip an update and diverge
  with no way to notice.
  """
  def state(doc_id) do
    AshCell.transaction(doc_id, fn ->
      head = head_seq(doc_id)

      %{
        document: fetch_document!(doc_id),
        update: merged_state(doc_id),
        head: head
      }
    end)
  end

  @doc """
  Stores one Yjs update and broadcasts it.

  Returns `{:ok, seq}`. Storing before broadcasting is the ordering that matters:
  a client can only be told about an update that is already durable, so a node
  dying between the two loses nothing that anybody has seen.
  """
  def append(doc_id, update, client_id) when is_binary(update) do
    result =
      AshCell.transaction(doc_id, fn ->
        seq = head_seq(doc_id) + 1

        {:ok, _} =
          Update.create(
            %{
              seq: seq,
              payload: update,
              client_id: client_id,
              at: DateTime.utc_now() |> DateTime.truncate(:second)
            },
            tenant: doc_id
          )

        seq
      end)

    with {:ok, seq} <- result do
      Phoenix.PubSub.broadcast(
        @pubsub,
        topic(doc_id),
        {:update, %{seq: seq, update: update, client_id: client_id}}
      )

      {:ok, seq}
    end
  end

  @doc """
  Relays awareness — cursors, selections, names — without storing it.

  Deliberately not a write. Awareness is worthless a second after it is produced,
  and a cell's single connection is the wrong thing to spend on it.
  """
  def relay_awareness(doc_id, update, client_id) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      topic(doc_id),
      {:awareness, %{update: update, client_id: client_id}}
    )
  end

  @doc """
  Updates after `seq`, oldest first — the resume path for a client that dropped
  its websocket.

  If compaction has already absorbed everything the client missed, there is
  nothing to replay incrementally and it needs the snapshot instead; that is what
  the `:compacted_past` return says.
  """
  def updates_since(doc_id, seq) do
    AshCell.transaction(doc_id, fn ->
      if seq < snapshot_through(doc_id) do
        :compacted_past
      else
        Update
        |> Ash.Query.filter(seq > ^seq)
        |> Ash.Query.sort(seq: :asc)
        |> Ash.read!(tenant: doc_id)
        |> Enum.map(&%{seq: &1.seq, update: &1.payload, client_id: &1.client_id})
      end
    end)
  end

  @doc """
  Merges the log into a snapshot and truncates what it merged.

  **This is the operation the cell exists for.** It is a read-modify-write over the
  whole log, and it is one transaction on one connection held by one node, so it
  needs no lock and no retry. `AshCell.transaction/2` means a cell taken
  mid-compaction aborts it: the alternative — a truncated log with no snapshot — is
  the one failure mode here that would actually lose a document.

  Returns what it did, so the UI can show it.
  """
  def compact(doc_id) do
    AshCell.transaction(doc_id, fn ->
      head = head_seq(doc_id)
      pending = Ash.read!(Update, tenant: doc_id)
      state = merged_state(doc_id)

      {:ok, _} =
        Snapshot.put(
          %{
            id: @snapshot_id,
            state: state,
            through_seq: head,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          tenant: doc_id
        )

      # Only what the snapshot provably contains. Anything appended after `head`
      # was read stays in the log — and cannot be, because this transaction holds
      # the cell's only connection.
      merged = Enum.filter(pending, &(&1.seq <= head))
      Enum.each(merged, &Update.destroy!(&1, tenant: doc_id))

      %{
        merged: length(merged),
        through_seq: head,
        log_bytes: Enum.reduce(merged, 0, &(byte_size(&1.payload) + &2)),
        snapshot_bytes: byte_size(state)
      }
    end)
  end

  @doc """
  Numbers for the UI: how much log is outstanding, and how big the cell is.

  Returns `:unavailable` for a cell that cannot be read — a shredded key, a
  quarantined migration, a file that is not one of ours. The document list is a
  fan-out over every cell, so one unreadable cell must not take out the list; that
  is the per-cell failure mode the spec calls a single-tenant outage, and it stays
  single-tenant only if callers handle it.
  """
  def stats(doc_id) do
    cell_key = CellKey.resolve(doc_id)
    path = AshCell.path_for(cell_key)
    pending = Ash.read!(Update, tenant: doc_id)

    %{
      pending: length(pending),
      pending_bytes: Enum.reduce(pending, 0, &(byte_size(&1.payload) + &2)),
      snapshot_bytes: snapshot_bytes(doc_id),
      through_seq: snapshot_through(doc_id),
      head: head_seq(doc_id),
      file_bytes: file_size(path)
    }
  rescue
    _ -> :unavailable
  end

  @doc """
  The document's state as one update: the snapshot, plus every update after it,
  merged.

  Merged *server-side* by `y_ex` (a Rust NIF over `yrs`), not relayed blindly.
  Without a real Yjs implementation here, the server could store updates but never
  compact them — and compaction is the whole argument for the cell.
  """
  def merged_state(doc_id) do
    doc = Yex.Doc.new()

    case snapshot(doc_id) do
      nil -> :ok
      %{state: state} -> :ok = Yex.apply_update(doc, state)
    end

    Update
    |> Ash.Query.sort(seq: :asc)
    |> Ash.read!(tenant: doc_id)
    |> Enum.each(fn %{payload: payload} -> :ok = Yex.apply_update(doc, payload) end)

    Yex.encode_state_as_update!(doc)
  end

  def fetch_document(doc_id) do
    case Ash.read!(Document, tenant: doc_id) do
      [document] -> {:ok, document}
      _ -> :error
    end
  rescue
    # An unopenable cell — shredded key, or a file that is not one of ours.
    _ -> :error
  end

  def fetch_document!(doc_id) do
    {:ok, document} = fetch_document(doc_id)
    document
  end

  defp snapshot(doc_id) do
    case Ash.read!(Snapshot, tenant: doc_id) do
      [snapshot | _] -> snapshot
      [] -> nil
    end
  end

  defp snapshot_through(doc_id) do
    case snapshot(doc_id) do
      nil -> 0
      %{through_seq: seq} -> seq
    end
  end

  defp snapshot_bytes(doc_id) do
    case snapshot(doc_id) do
      nil -> 0
      %{state: state} -> byte_size(state)
    end
  end

  # No aggregates in AshSqlite, so the head is a sorted read of one row rather
  # than `max(seq)`. On a primary-key index that is the same query plan.
  defp head_seq(doc_id) do
    Update
    |> Ash.Query.sort(seq: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(tenant: doc_id)
    |> case do
      [%{seq: seq}] -> seq
      [] -> snapshot_through(doc_id)
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp cell_dir, do: Application.get_env(:collab_editor, :cell_dir, "priv/cells")
end
