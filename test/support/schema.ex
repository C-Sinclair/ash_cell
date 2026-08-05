defmodule AshCell.TestSchema do
  @moduledoc "Migrator for test cells. Runs before a cell serves traffic."
  def run(repo_pid) do
    Ecto.Adapters.SQL.query!(repo_pid, """
    CREATE TABLE IF NOT EXISTS tenant_patients (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL
    )
    """)

    Ecto.Adapters.SQL.query!(repo_pid, """
    CREATE TABLE IF NOT EXISTS patients (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL
    )
    """)
  end
end
