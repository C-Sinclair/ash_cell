defmodule AshCell.TestCellMigrations.Failing.AlterMissingTable do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE does_not_exist ADD COLUMN nope TEXT")
  end
end
