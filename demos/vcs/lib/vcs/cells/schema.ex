defmodule Vcs.Cells.Schema do
  @moduledoc """
  Versioned schema for one repository's cell, applied before the cell serves.

  `commit_paths` is the interesting table. It is the commit's tree, flattened at push time,
  which is what turns "which commits touched this path" from an object walk into an index
  scan. Git cannot keep this table without giving up its append-only object directory; a cell
  can, because a cell is a database.
  """
  use AshCell.Migrator

  migration(1, """
  CREATE TABLE objects (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    size INTEGER NOT NULL,
    body BLOB NOT NULL
  )
  """)

  migration(2, """
  CREATE TABLE commits (
    id TEXT PRIMARY KEY,
    parent_id TEXT,
    tree_id TEXT NOT NULL,
    message TEXT NOT NULL,
    author TEXT,
    committed_at TEXT NOT NULL
  )
  """)

  migration(3, """
  CREATE TABLE commit_paths (
    commit_id TEXT NOT NULL,
    path TEXT NOT NULL,
    blob_id TEXT NOT NULL,
    size INTEGER NOT NULL,
    PRIMARY KEY (commit_id, path)
  )
  """)

  migration(4, """
  CREATE TABLE refs (
    name TEXT PRIMARY KEY,
    commit_id TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  """)

  migration(5, fn repo_pid ->
    for sql <- [
          "CREATE INDEX commit_paths_path ON commit_paths(path)",
          "CREATE INDEX commits_parent ON commits(parent_id)"
        ] do
      Ecto.Adapters.SQL.query!(repo_pid, sql, [])
    end
  end)
end
