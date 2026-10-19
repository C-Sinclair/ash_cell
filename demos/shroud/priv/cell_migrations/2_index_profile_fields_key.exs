defmodule Shroud.CellMigrations.IndexProfileFieldsKey do
  use Ecto.Migration

  def up do
    execute("CREATE UNIQUE INDEX profile_fields_key ON profile_fields(key)")
  end
end
