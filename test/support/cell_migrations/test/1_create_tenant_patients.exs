defmodule AshCell.TestCellMigrations.Test.CreateTenantPatients do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE tenant_patients (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL
    )
    """)
  end
end
