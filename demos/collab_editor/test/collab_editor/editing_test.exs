defmodule CollabEditor.EditingTest do
  @moduledoc """
  The claims the demo makes, as tests rather than prose.

  Two groups matter most. "convergence" is Yjs's guarantee and is here to show it
  survives the round trip through the cell rather than to prove Yjs works.
  "compaction" is the cell's guarantee, and is the reason the demo exists.
  """
  use ExUnit.Case, async: false

  import CollabEditor.YjsHelpers

  alias CollabEditor.{CellKey, Editing}

  setup do
    {:ok, document} = Editing.create_document("Test document")
    on_exit(fn -> Editing.delete_document(document.id) end)
    %{doc: document}
  end

  describe "a document is a cell" do
    test "each document gets its own file on disk", %{doc: doc} do
      {:ok, other} = Editing.create_document("Another document")
      on_exit(fn -> Editing.delete_document(other.id) end)

      path = AshCell.path_for(CellKey.resolve(doc.id))
      other_path = AshCell.path_for(CellKey.resolve(other.id))

      assert path != other_path
      assert File.exists?(path)
      assert File.exists?(other_path)
    end

    test "the cell key namespaces the document id, and encodes injectively", %{doc: doc} do
      cell_key = CellKey.resolve(doc.id)

      assert cell_key == "doc:" <> doc.id
      assert {:ok, ^cell_key} = AshCell.CellKey.decode(AshCell.CellKey.encode(cell_key))
      refute AshCell.path_for(cell_key) =~ ":"
    end

    test "an update stored in one document is invisible in another", %{doc: doc} do
      {:ok, other} = Editing.create_document("Another document")
      on_exit(fn -> Editing.delete_document(other.id) end)

      {:ok, _} = Editing.append(doc.id, update_inserting("only here"), "client-1")

      assert text_of(Editing.merged_state(doc.id)) == "only here"
      assert text_of(Editing.merged_state(other.id)) == ""
    end

    test "deleting a document removes the bytes rather than marking a row", %{doc: doc} do
      {:ok, _} = Editing.append(doc.id, update_inserting("sensitive"), "client-1")
      path = AshCell.path_for(CellKey.resolve(doc.id))
      assert File.exists?(path)

      Editing.delete_document(doc.id)

      refute File.exists?(path)
    end
  end

  describe "convergence" do
    test "two clients' concurrent edits both survive the round trip", %{doc: doc} do
      {:ok, _} = Editing.append(doc.id, update_inserting("alpha"), "client-1")
      {:ok, _} = Editing.append(doc.id, update_inserting("beta"), "client-2")

      text = text_of(Editing.merged_state(doc.id))

      assert text =~ "alpha"
      assert text =~ "beta"
    end

    test "concurrent appends get consecutive sequence numbers, with no duplicates",
         %{doc: doc} do
      # The order does not decide the document — CRDT updates commute — but it does
      # make an incremental resume answerable, and the cell gives it for free:
      # `read head; write head + 1` cannot lose an update on one connection.
      seqs =
        1..20
        |> Task.async_stream(
          fn i ->
            {:ok, seq} = Editing.append(doc.id, update_inserting("c#{i} "), "client-#{i}")
            seq
          end,
          max_concurrency: 20,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, seq} -> seq end)

      assert Enum.sort(seqs) == Enum.to_list(1..20)

      text = text_of(Editing.merged_state(doc.id))
      for i <- 1..20, do: assert(text =~ "c#{i} ")
    end

    test "updates_since answers exactly, which is what makes a reconnect cheap", %{doc: doc} do
      for i <- 1..5 do
        {:ok, _} = Editing.append(doc.id, update_inserting("c#{i}"), "client-1")
      end

      {:ok, tail} = Editing.updates_since(doc.id, 3)

      assert Enum.map(tail, & &1.seq) == [4, 5]
    end
  end

  describe "compaction — what the cell is actually for" do
    test "merging the log into a snapshot preserves the document exactly", %{doc: doc} do
      for word <- ~w(one two three four) do
        {:ok, _} = Editing.append(doc.id, update_inserting(word <> " "), "client-1")
      end

      before = text_of(Editing.merged_state(doc.id))
      {:ok, result} = Editing.compact(doc.id)

      assert result.merged == 4
      assert result.through_seq == 4
      assert text_of(Editing.merged_state(doc.id)) == before
      # The log is gone; the snapshot is the document now.
      assert Editing.stats(doc.id).pending == 0
      assert Editing.stats(doc.id).snapshot_bytes > 0
    end

    test "compaction concurrent with appends loses nothing", %{doc: doc} do
      # This is the test the demo exists for. On shared storage, an update that
      # arrives between a compactor's read of the log and its delete of that log is
      # gone — no lock, no retry, and a CRDT cannot repair it because the update is
      # not anywhere any more.
      #
      # Here compaction and appends contend for one connection on one cell, so they
      # serialise: whichever order they land in, every update is either in the
      # snapshot or still in the log.
      writers =
        for i <- 1..15 do
          Task.async(fn ->
            {:ok, _} = Editing.append(doc.id, update_inserting("w#{i} "), "client-#{i}")
          end)
        end

      compactors = for _ <- 1..4, do: Task.async(fn -> Editing.compact(doc.id) end)

      Task.await_many(writers ++ compactors, 30_000)

      text = text_of(Editing.merged_state(doc.id))

      for i <- 1..15 do
        assert text =~ "w#{i} ", "update w#{i} was lost across concurrent compaction"
      end
    end

    test "repeated compaction is idempotent and keeps the document", %{doc: doc} do
      {:ok, _} = Editing.append(doc.id, update_inserting("stable"), "client-1")

      {:ok, first} = Editing.compact(doc.id)
      {:ok, second} = Editing.compact(doc.id)

      assert first.merged == 1
      assert second.merged == 0
      assert text_of(Editing.merged_state(doc.id)) == "stable"
    end

    test "a client that missed compacted updates is told to take the snapshot",
         %{doc: doc} do
      for i <- 1..3 do
        {:ok, _} = Editing.append(doc.id, update_inserting("c#{i}"), "client-1")
      end

      {:ok, _} = Editing.compact(doc.id)

      # Asking for the tail after seq 1 cannot be answered incrementally — seq 1 is
      # inside the snapshot now. Saying so beats silently returning a short tail and
      # letting the client diverge.
      assert {:ok, :compacted_past} = Editing.updates_since(doc.id, 1)
      # A client that is up to date still resumes incrementally.
      assert {:ok, []} = Editing.updates_since(doc.id, 3)
    end

    test "the snapshot survives a cell close and reopen", %{doc: doc} do
      {:ok, _} = Editing.append(doc.id, update_inserting("durable"), "client-1")
      {:ok, _} = Editing.compact(doc.id)

      AshCell.close(CellKey.resolve(doc.id))

      assert text_of(Editing.merged_state(doc.id)) == "durable"
    end
  end

  describe "awareness is relayed, never stored" do
    test "a cursor update reaches subscribers and touches no table", %{doc: doc} do
      Editing.subscribe(doc.id)
      before = Editing.stats(doc.id)

      Editing.relay_awareness(doc.id, "opaque-awareness-bytes", "client-1")

      assert_receive {:awareness, %{update: "opaque-awareness-bytes", client_id: "client-1"}}
      assert Editing.stats(doc.id).pending == before.pending
      assert Editing.stats(doc.id).file_bytes == before.file_bytes
    end
  end

  describe "what a per-document cell costs" do
    test "a transaction cannot span two documents", %{doc: doc} do
      {:ok, other} = Editing.create_document("Another document")
      on_exit(fn -> Editing.delete_document(other.id) end)

      assert_raise ArgumentError, ~r/cannot open a transaction/, fn ->
        AshCell.transaction(doc.id, fn ->
          AshCell.transaction(other.id, fn -> :never end)
        end)
      end
    end

    test "listing documents is a fan-out over cells, and finds them all", %{doc: doc} do
      {:ok, other} = Editing.create_document("Another document")
      on_exit(fn -> Editing.delete_document(other.id) end)

      ids = Editing.list_documents() |> Enum.map(& &1.id)

      assert doc.id in ids
      assert other.id in ids
    end
  end

  describe "broadcasting" do
    test "a stored update reaches subscribers with its sequence number", %{doc: doc} do
      Editing.subscribe(doc.id)
      update = update_inserting("hello")

      {:ok, seq} = Editing.append(doc.id, update, "client-1")

      assert_receive {:update, %{seq: ^seq, client_id: "client-1", update: ^update}}
    end
  end
end
