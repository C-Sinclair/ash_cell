defmodule Shroud.CellMigrations.CreateGrants do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE grants (
      id TEXT PRIMARY KEY,
      field_key TEXT NOT NULL,
      audience_slug TEXT NOT NULL,
      wrapped_content_key TEXT NOT NULL,
      iv TEXT NOT NULL,
      generation INTEGER NOT NULL DEFAULT 1,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end
end
