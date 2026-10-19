defmodule CollabEditor.CellMigrations.CreateSnapshots do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE snapshots (
      id TEXT PRIMARY KEY,
      state BLOB NOT NULL,
      through_seq INTEGER NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end
end
