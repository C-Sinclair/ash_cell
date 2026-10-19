defmodule Vcs.CellMigrations.CreateCommitPaths do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE commit_paths (
      commit_id TEXT NOT NULL,
      path TEXT NOT NULL,
      blob_id TEXT NOT NULL,
      size INTEGER NOT NULL,
      PRIMARY KEY (commit_id, path)
    )
    """)
  end
end
