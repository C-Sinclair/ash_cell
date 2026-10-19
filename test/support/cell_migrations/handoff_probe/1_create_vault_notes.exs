defmodule AshCell.TestCellMigrations.HandoffProbe.CreateVaultNotes do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE vault_notes (
      id TEXT PRIMARY KEY,
      body TEXT NOT NULL,
      handoff_state TEXT NOT NULL DEFAULT 'owned',
      handoff_id TEXT,
      promoted_to TEXT
    )
    """)
  end
end
