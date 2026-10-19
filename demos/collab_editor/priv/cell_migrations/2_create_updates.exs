defmodule CollabEditor.CellMigrations.CreateUpdates do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE updates (
      seq INTEGER PRIMARY KEY,
      payload BLOB NOT NULL,
      client_id TEXT,
      at TEXT NOT NULL
    )
    """)
  end
end
