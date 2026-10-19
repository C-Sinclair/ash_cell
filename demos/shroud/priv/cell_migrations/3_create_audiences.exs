defmodule Shroud.CellMigrations.CreateAudiences do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE audiences (
      id TEXT PRIMARY KEY,
      slug TEXT NOT NULL,
      name TEXT NOT NULL,
      wrapped_group_key TEXT NOT NULL,
      iv TEXT NOT NULL,
      generation INTEGER NOT NULL DEFAULT 1,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end
end
