defmodule AshCell.TestCellMigrations.HandoffProbe.CreateImportsByAttempt do
  use Ecto.Migration

  def up do
    # The key that was proposed and is wrong, kept so the probe can show the
    # difference rather than assert it.
    execute("""
    CREATE TABLE imports_by_attempt (
      source_cell TEXT NOT NULL,
      record_id TEXT NOT NULL,
      attempt_id TEXT NOT NULL,
      PRIMARY KEY (source_cell, record_id, attempt_id)
    )
    """)
  end
end
