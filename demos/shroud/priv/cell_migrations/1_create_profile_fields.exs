defmodule Shroud.CellMigrations.CreateProfileFields do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE profile_fields (
      id TEXT PRIMARY KEY,
      key TEXT NOT NULL,
      ciphertext TEXT NOT NULL,
      iv TEXT NOT NULL,
      content_key_id TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end
end
