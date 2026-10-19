defmodule Vcs.CellMigrations.CreateObjects do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE objects (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      size INTEGER NOT NULL,
      body BLOB NOT NULL
    )
    """)
  end
end
