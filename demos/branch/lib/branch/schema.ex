defmodule Branch.Schema do
  @moduledoc """
  What a freshly provisioned database starts as: almost nothing.

  This demo hands the user a SQL console, so the tables in a cell are the user's,
  created by their own DDL. The only thing the migrations install is a marker table,
  so that a cell has a known baseline and `schema_migrations` has something to
  record — a cell restored from an older snapshot is still brought forward before
  its first read.

  That is a deliberate difference from every other demo, where the schema is the
  application's and its migrations own it. Here the schema is *data*, which is what
  makes branching interesting: a branch can contain a schema change, and merging it
  is how the change reaches the origin.

  The migrations themselves are the files in `priv/cell_migrations`.
  """

  @doc "Where this demo's cell migrations are, for the fleet's `migrations_path:`."
  def migrations_path, do: Application.app_dir(:branch, "priv/cell_migrations")
end
