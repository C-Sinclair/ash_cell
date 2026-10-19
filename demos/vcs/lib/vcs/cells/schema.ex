defmodule Vcs.Cells.Schema do
  @moduledoc """
  Versioned schema for one repository's cell, applied before the cell serves.

  `commit_paths` is the interesting table. It is the commit's tree, flattened at push time,
  which is what turns "which commits touched this path" from an object walk into an index
  scan. Git cannot keep this table without giving up its append-only object directory; a cell
  can, because a cell is a database.

  The migrations themselves are the files in `priv/cell_migrations`.
  """

  @doc "Where this demo's cell migrations are, for the fleet's `migrations_path:`."
  def migrations_path, do: Application.app_dir(:vcs, "priv/cell_migrations")
end
