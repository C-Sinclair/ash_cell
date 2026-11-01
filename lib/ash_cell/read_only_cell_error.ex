defmodule AshCell.ReadOnlyCellError do
  @moduledoc """
  Raised when a write reaches a cell opened with `AshCell.open_read_only/2`.

  The statement did not run. This node does not hold the cell's lease, so a write
  here would land in a local copy that never ships. Claim the cell with
  `AshCell.claim/2` to write to it.
  """

  defexception [:cell_key]

  @impl true
  def message(%{cell_key: cell_key}) do
    "cell #{inspect(cell_key)} is open read-only on this node; claim it with AshCell.claim/2 to write"
  end
end
