defmodule Shroud.CellMigrations.IndexAudiencesSlug do
  use Ecto.Migration

  def up do
    execute("CREATE UNIQUE INDEX audiences_slug ON audiences(slug)")
  end
end
