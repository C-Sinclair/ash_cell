defmodule Relay.CellMigrations.CreateGeneration do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE generation (
      id TEXT PRIMARY KEY,
      prompt TEXT NOT NULL,
      started_at INTEGER NOT NULL,
      finished_at INTEGER
    )
    """)
  end
end
