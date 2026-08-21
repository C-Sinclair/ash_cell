defmodule CollabEditor.YjsHelpers do
  @moduledoc """
  Building real Yjs updates in tests, with `y_ex` — the same library the server
  compacts with.

  Each "client" here is its own `Yex.Doc`, exactly as two browsers are. Its whole
  state is a valid update to apply anywhere, which is the CRDT property the demo
  leans on: these tests do not simulate merging, they merge.
  """

  @doc "An update from a fresh client that inserted `text` at the root."
  def update_inserting(text) do
    doc = Yex.Doc.new()
    doc |> Yex.Doc.get_text("root") |> Yex.Text.insert(0, text)
    Yex.encode_state_as_update!(doc)
  end

  @doc "The text a merged update decodes to."
  def text_of(update) do
    doc = Yex.Doc.new()
    :ok = Yex.apply_update(doc, update)
    doc |> Yex.Doc.get_text("root") |> Yex.Text.to_string()
  end
end
