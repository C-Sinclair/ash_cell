defmodule AshCell.TestCellMigrations.HandoffProbe.CreateImportedNotes do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE imported_notes (
      id TEXT PRIMARY KEY,
      body TEXT NOT NULL
    )
    """)
  end
end
