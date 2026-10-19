defmodule Demo.CellMigrations.CreatePatients do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE patients (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      mrn TEXT,
      birth_year INTEGER,
      risk_score INTEGER DEFAULT 0
    )
    """)
  end
end
