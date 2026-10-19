defmodule Shroud.CellMigrations.CreatePosts do
  use Ecto.Migration

  def up do
    # `body` holds plaintext for public posts and stays NULL for audience posts,
    # which store `ciphertext` instead -- see Shroud.Profile.Post for why a public post
    # is deliberately not encrypted.
    execute("""
    CREATE TABLE posts (
      id TEXT PRIMARY KEY,
      visibility TEXT NOT NULL,
      body TEXT,
      ciphertext TEXT,
      iv TEXT,
      content_key_id TEXT,
      wrapped_content_key TEXT,
      wrap_iv TEXT,
      own_wrapped_content_key TEXT,
      own_wrap_iv TEXT,
      posted_at TEXT NOT NULL
    )
    """)
  end
end
