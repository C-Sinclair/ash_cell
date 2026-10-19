defmodule Demo.CellMigrations.CreateEncounters do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE encounters (
      id TEXT PRIMARY KEY,
      patient_id TEXT,
      reason TEXT,
      occurred_on TEXT
    )
    """)
  end
end
