defmodule CollabEditor.CellKey do
  @moduledoc """
  One cell per **document**.

  The default resolver (`AshCell.CellKey.Identity`) makes a cell out of whatever
  Ash carries as the tenant, which for the console demo is a customer. Here the
  cut is one level finer: the tenant value is a document id, and the cell key is
  that id under a `doc:` prefix.

  The prefix is not decoration. A cell key becomes a filename and an object-store
  prefix, and a namespace makes it possible to keep other cuts in the same store
  later — `presence:<room>`, `audit:<year>` — without two schemes colliding in one
  directory. `AshCell.CellKey.encode/1` escapes the `:` on the way to disk, so the
  file is `doc~3A<uuid>.db` and the mapping stays injective.

  ## Why a document is a defensible cell

  A cell is a serialising single writer over an encrypted file with its own
  snapshot lineage. That is a heavy object to hand to a row — the fleet-wide
  problems (deploy migrates every cell, thundering herd on node loss) scale with
  cell *count*, so cutting finer costs more of exactly the thing that is already
  unsolved.

  It is worth it here because the unit of collaboration and the unit of
  contention are the same object. A document is edited by a handful of people at
  once, needs its edit history kept somewhere bounded, and never needs a
  transaction or a join with another document. That last clause is the test:
  anything a cell refuses (cross-cell transactions, cross-cell queries) is
  something a document did not want anyway.

  Note what the cell is *not* doing here: it is not what makes concurrent editing
  correct. Yjs is. See `CollabEditor.Editing` for the division of labour, which is
  narrower and more defensible than "the cell orders your edits".

  ## What it costs, stated plainly

    * No transaction can span two documents. Moving content from one document to
      another is therefore two writes with a window in between, not one commit.
      `AshCell.transaction/2` raises rather than half-applying.
    * "List all documents" is a fan-out over cells, not a query. See
      `CollabEditor.Docs.list_documents/0`, which opens every cell to read one
      row — honest about the cost rather than hiding it behind an index.
    * A deploy migrates one cell per document rather than one per customer.
  """

  @behaviour AshCell.CellKey

  @impl true
  def resolve({:doc, id}), do: "doc:" <> to_string(id)
  def resolve("doc:" <> _ = key), do: key
  def resolve(id) when is_binary(id) and byte_size(id) > 0, do: "doc:" <> id

  def resolve(other) do
    raise ArgumentError, """
    cannot resolve #{inspect(other)} to a document cell.

    Pass a document id, or `{:doc, id}` to be explicit about the cut.
    """
  end

  @doc """
  The document id inside a cell key, for tooling that has a filename and wants the
  document back.
  """
  @spec document_id(binary()) :: {:ok, binary()} | :error
  def document_id("doc:" <> id) when byte_size(id) > 0, do: {:ok, id}
  def document_id(_), do: :error
end
