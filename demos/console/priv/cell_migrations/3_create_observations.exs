defmodule Demo.CellMigrations.CreateObservations do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE observations (
      id TEXT PRIMARY KEY,
      encounter_id TEXT,
      code TEXT,
      value INTEGER
    )
    """)
  end
end
