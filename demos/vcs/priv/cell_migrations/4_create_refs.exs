defmodule Vcs.CellMigrations.CreateRefs do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE refs (
      name TEXT PRIMARY KEY,
      commit_id TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end
end
