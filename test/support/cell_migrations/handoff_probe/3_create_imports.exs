defmodule AshCell.TestCellMigrations.HandoffProbe.CreateImports do
  use Ecto.Migration

  def up do
    # The key the design settled on: the *record's* identity, not the attempt's.
    execute("""
    CREATE TABLE imports (
      source_cell TEXT NOT NULL,
      record_id TEXT NOT NULL,
      attempt_id TEXT NOT NULL,
      PRIMARY KEY (source_cell, record_id)
    )
    """)
  end
end
