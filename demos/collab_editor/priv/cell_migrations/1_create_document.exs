defmodule CollabEditor.CellMigrations.CreateDocument do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE document (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
    """)
  end
end
