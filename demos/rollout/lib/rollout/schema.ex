defmodule Rollout.Schema do
  @moduledoc """
  A channel cell's schema, applied before the cell serves anything.

  Versioned by `AshCell.Migrations` from `priv/cell_migrations`, so a cell restored
  from a snapshot taken at an older version is brought forward before its first
  read rather than answering against a schema nobody expects.
  """

  @doc "Where this demo's cell migrations are, for the fleet's `migrations_path:`."
  def migrations_path, do: Application.app_dir(:rollout, "priv/cell_migrations")
end
