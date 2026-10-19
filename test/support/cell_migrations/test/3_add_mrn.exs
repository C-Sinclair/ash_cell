defmodule AshCell.TestCellMigrations.Test.AddMrn do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE tenant_patients ADD COLUMN mrn TEXT")
  end
end
