defmodule AshCell.CellUnavailableError do
  @moduledoc """
  Raised when a tenant's cell cannot be bound for a statement that needs it.

  The statement did not run. Nothing was read and nothing was written, because
  there was no database to read or write against — which is the only acceptable
  outcome, the alternative being a statement issued against whichever cell the
  process happened to be holding.
  """

  defexception [:tenant, :reason]

  @impl true
  def message(%{tenant: tenant, reason: reason}) do
    """
    could not bind the cell for tenant #{inspect(tenant)}: #{inspect(reason)}

    The statement was not run. Depending on the reason this is transient -- a cell
    closing for a drain, or a lease held by another node -- and retrying the request
    is reasonable. If it is `:cell_unavailable`, the cell could not be started at
    all and the tenant is down until that is fixed.
    """
  end
end
