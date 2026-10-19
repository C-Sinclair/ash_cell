defmodule Vcs.CellMigrations.CreateCommits do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE commits (
      id TEXT PRIMARY KEY,
      parent_id TEXT,
      tree_id TEXT NOT NULL,
      message TEXT NOT NULL,
      author TEXT,
      committed_at TEXT NOT NULL
    )
    """)
  end
end
