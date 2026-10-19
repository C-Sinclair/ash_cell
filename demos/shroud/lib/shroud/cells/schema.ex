defmodule Shroud.Cells.Schema do
  @moduledoc """
  Versioned schema for one user's cell, applied on activation before the cell
  serves traffic.

  Migration here is a fleet operation, and there is no moment at which every user
  is on the same schema. The mitigation is blast radius: a failure takes out one
  user rather than all of them, and `AshCell.Manager.quarantined/0` records it
  rather than logging it into the night.

  Run `mix ash_cell.migrate` at deploy time so failures surface while somebody is
  watching. Lazy activation is the fallback, not the plan.

  Note that the ciphertext columns are `TEXT`. The payloads are base64 rather than
  raw `BLOB`, because they cross into JavaScript on every read and back on every
  write, and base64 is what `JSON.stringify` can carry without a second encoding
  step. The cost is ~33% on the ciphertext columns, paid to keep exactly one
  encoding boundary in the system instead of two.

  The migrations themselves are the files in `priv/cell_migrations`.
  """

  @doc "Where this demo's cell migrations are, for the fleet's `migrations_path:`."
  def migrations_path, do: Application.app_dir(:shroud, "priv/cell_migrations")
end
