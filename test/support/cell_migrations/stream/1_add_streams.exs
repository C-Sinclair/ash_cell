defmodule AshCell.TestCellMigrations.Stream.AddStreams do
  use Ecto.Migration

  def up do
    AshCell.Stream.Migration.up()
  end
end
