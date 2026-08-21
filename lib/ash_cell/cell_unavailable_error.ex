defmodule AshCell.CellUnavailableError do
  @moduledoc """
  Raised when a cell cannot be bound for a statement that needs it.

  The statement did not run. Nothing was read and nothing was written, because
  there was no database to read or write against — which is the only acceptable
  outcome, the alternative being a statement issued against whichever cell the
  process happened to be holding.
  """

  defexception [:cell_key, :reason]

  @impl true
  def message(%{cell_key: cell_key, reason: reason}) do
    """
    could not bind the cell for cell_key #{inspect(cell_key)}: #{inspect(reason)}

    The statement was not run. Depending on the reason this is transient -- a cell
    closing for a drain, or a lease held by another node -- and retrying the request
    is reasonable. If it is `:cell_unavailable`, the cell could not be started at
    all and the cell_key is down until that is fixed.
    """
  end
end
