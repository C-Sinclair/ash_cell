defmodule Branch.Schema do
  @moduledoc """
  What a freshly provisioned database starts as: almost nothing.

  This demo hands the user a SQL console, so the tables in a cell are the user's,
  created by their own DDL. The only thing the migrator installs is a marker table,
  so that a cell has a known baseline and `PRAGMA user_version` has something to be
  at — a cell restored from an older snapshot is still brought forward before its
  first read.

  That is a deliberate difference from every other demo, where the schema is the
  application's and the migrator owns it. Here the schema is *data*, which is what
  makes branching interesting: a branch can contain a schema change, and merging it
  is how the change reaches the origin.
  """

  def target_version, do: migrations() |> Enum.map(&elem(&1, 0)) |> Enum.max()

  def migrations do
    [{1, &statements(&1, version_1())}]
  end

  defp statements(repo_pid, sql) do
    Enum.each(sql, &Ecto.Adapters.SQL.query!(repo_pid, &1, []))
  end

  defp version_1 do
    [
      """
      CREATE TABLE _branch_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      """
    ]
  end
end
