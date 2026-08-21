defmodule CollabEditorWeb.EditorLiveTest do
  @moduledoc """
  The wire path: a browser's Yjs update reaches the cell, another browser's update
  reaches the browser, and awareness passes through without being stored.
  """
  use CollabEditorWeb.ConnCase, async: false

  import CollabEditor.YjsHelpers

  alias CollabEditor.Editing

  setup do
    {:ok, document} = Editing.create_document("Wire test")
    on_exit(fn -> Editing.delete_document(document.id) end)
    %{doc: document}
  end

  test "the index lists a document with its cell on disk", %{conn: conn, doc: doc} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Wire test"
    assert html =~ "doc~3A" <> doc.id
  end

  test "the editor is handed the document's merged state, not its history",
       %{conn: conn, doc: doc} do
    {:ok, _} = Editing.append(doc.id, update_inserting("already here"), "someone")
    {:ok, _} = Editing.compact(doc.id)

    {:ok, _view, html} = live(conn, ~p"/docs/#{doc.id}")

    [_, encoded] = Regex.run(~r/data-state="([^"]*)"/, html)
    {:ok, state} = encoded |> String.replace("&#39;", "'") |> Base.decode64()

    assert text_of(state) == "already here"
  end

  test "an update from the browser is stored in the cell", %{conn: conn, doc: doc} do
    {:ok, view, _html} = live(conn, ~p"/docs/#{doc.id}")

    render_hook(view, "update", %{"update" => Base.encode64(update_inserting("typed"))})

    assert text_of(Editing.merged_state(doc.id)) == "typed"
    assert Editing.stats(doc.id).pending == 1
  end

  test "another client's update is pushed to the browser, and its own echo is not",
       %{conn: conn, doc: doc} do
    {:ok, view, _html} = live(conn, ~p"/docs/#{doc.id}")

    {:ok, seq} = Editing.append(doc.id, update_inserting("from elsewhere"), "some-other-client")

    assert_push_event(view, "remote_update", %{seq: ^seq, update: encoded})
    assert text_of(Base.decode64!(encoded)) == "from elsewhere"

    render_hook(view, "update", %{"update" => Base.encode64(update_inserting("mine"))})

    refute_push_event(view, "remote_update", %{seq: _}, 50)
  end

  test "awareness is relayed to other clients and stored nowhere", %{conn: conn, doc: doc} do
    {:ok, view, _html} = live(conn, ~p"/docs/#{doc.id}")
    before = Editing.stats(doc.id)

    Editing.relay_awareness(doc.id, "cursor-bytes", "some-other-client")

    assert_push_event(view, "remote_awareness", %{update: "cursor-bytes"})
    assert Editing.stats(doc.id).pending == before.pending
  end

  test "a reconnecting client replays only the updates it missed", %{conn: conn, doc: doc} do
    for i <- 1..3 do
      {:ok, _} = Editing.append(doc.id, update_inserting("c#{i}"), "other")
    end

    {:ok, view, _html} = live(conn, ~p"/docs/#{doc.id}")

    render_hook(view, "resume", %{"since" => 1})

    assert_push_event(view, "replay", %{updates: updates})
    assert Enum.map(updates, & &1.seq) == [2, 3]
  end

  test "a client that missed compacted updates is sent the snapshot instead",
       %{conn: conn, doc: doc} do
    {:ok, _} = Editing.append(doc.id, update_inserting("compacted away"), "other")
    {:ok, _} = Editing.compact(doc.id)

    {:ok, view, _html} = live(conn, ~p"/docs/#{doc.id}")

    render_hook(view, "resume", %{"since" => 0})

    assert_push_event(view, "reload", %{state: state, head: 1})
    assert text_of(Base.decode64!(state)) == "compacted away"
  end

  test "compacting from the UI reports what it merged", %{conn: conn, doc: doc} do
    for i <- 1..3 do
      {:ok, _} = Editing.append(doc.id, update_inserting("c#{i}"), "other")
    end

    {:ok, view, _html} = live(conn, ~p"/docs/#{doc.id}")

    html = render_click(view, "compact")

    assert html =~ "Merged 3 updates"
    assert Editing.stats(doc.id).pending == 0
  end

  test "renaming writes to the document's own cell", %{conn: conn, doc: doc} do
    {:ok, view, _html} = live(conn, ~p"/docs/#{doc.id}")

    render_change(view, "rename", %{"title" => "Renamed"})

    assert {:ok, %{title: "Renamed"}} = Editing.fetch_document(doc.id)
  end
end
