defmodule AshCell.TestCellMigrations.Test.CreatePatients do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE patients (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL
    )
    """)
  end
end
