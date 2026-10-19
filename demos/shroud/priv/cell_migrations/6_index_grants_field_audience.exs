defmodule Shroud.CellMigrations.IndexGrantsFieldAudience do
  use Ecto.Migration

  def up do
    execute("CREATE UNIQUE INDEX grants_field_audience ON grants(field_key, audience_slug)")
  end
end
