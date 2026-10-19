defmodule Demo.Cells.Schema do
  @moduledoc """
  Versioned schema for a clinic's cell, applied on activation before the cell
  serves traffic.

  Migration here is a *fleet* operation: there is no moment at which every clinic
  is on the same schema. The mitigation is that a failure takes down one clinic
  rather than all of them, and that failures are recorded (see
  `AshCell.Manager.quarantined/0`) instead of merely logged into the night.

  Run `mix ash_cell.migrate --tenants ...` at deploy time so failures surface
  while somebody is watching. Lazy activation is the fallback, not the plan.

  The migrations themselves are the files in `priv/cell_migrations`.
  """

  @doc "Where this demo's cell migrations are, for the fleet's `migrations_path:`."
  def migrations_path, do: Application.app_dir(:demo, "priv/cell_migrations")
end
