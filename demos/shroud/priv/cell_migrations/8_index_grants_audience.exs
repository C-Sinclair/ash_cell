defmodule Shroud.CellMigrations.IndexGrantsAudience do
  use Ecto.Migration

  def up do
    # The feed reads grants by audience, so that lookup is the one worth an index.
    execute("CREATE INDEX grants_audience ON grants(audience_slug)")
  end
end
