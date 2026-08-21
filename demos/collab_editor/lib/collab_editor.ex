defmodule CollabEditor do
  @moduledoc """
  A collaborative rich text editor where **one document is one cell**.

  The interesting modules, in reading order:

    * `CollabEditor.CellKey` — why a document is a defensible cell boundary, and
      what it costs
    * `CollabEditor.Cells.Schema` — the three tables inside a document
    * `CollabEditor.Editing` — the whole of the collaboration protocol, which is
      short because the cell already provides the total order
    * `CollabEditorWeb.EditorLive` — binding per callback, and holding the cell
      while somebody is typing in it
  """
end
