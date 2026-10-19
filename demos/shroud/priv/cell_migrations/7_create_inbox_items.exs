defmodule Shroud.CellMigrations.CreateInboxItems do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE inbox_items (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      ciphertext TEXT NOT NULL,
      iv TEXT NOT NULL,
      ephemeral_public_key TEXT NOT NULL,
      sender_handle TEXT,
      read_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end
end
