defmodule Rollout.Schema do
  @moduledoc """
  A channel cell's schema, applied before the cell serves anything.

  Versioned against `PRAGMA user_version` by `AshCell.Migrator`, so a cell restored
  from a snapshot taken at an older version is brought forward before its first
  read rather than answering against a schema nobody expects.
  """

  def target_version, do: migrations() |> Enum.map(&elem(&1, 0)) |> Enum.max()

  def migrations do
    [
      # A step is one SQL string or one function; several statements have to be a
      # function, and the whole step is one transaction either way.
      {1, &statements(&1, version_1())}
    ]
  end

  defp statements(repo_pid, sql) do
    Enum.each(sql, &Ecto.Adapters.SQL.query!(repo_pid, &1, []))
  end

  defp version_1 do
    [
      """
      CREATE TABLE releases (
        id TEXT PRIMARY KEY,
        version TEXT NOT NULL,
        notes TEXT,
        state TEXT NOT NULL DEFAULT 'draft',
        inserted_at TEXT NOT NULL
      )
      """,
      "CREATE UNIQUE INDEX releases_version ON releases (version)",
      """
      CREATE TABLE artifacts (
        id TEXT PRIMARY KEY,
        release_id TEXT NOT NULL REFERENCES releases (id) ON DELETE CASCADE,
        blob_hash TEXT NOT NULL,
        kind TEXT NOT NULL,
        platform TEXT NOT NULL,
        arch TEXT NOT NULL,
        size INTEGER NOT NULL,
        min_runtime INTEGER NOT NULL,
        max_runtime INTEGER
      )
      """,
      # The resolve path's index: release first, then the client facets it
      # filters on. Ordered to match the query so it is a range scan, not a scan
      # plus a filter.
      "CREATE INDEX artifacts_resolve ON artifacts (release_id, platform, arch, min_runtime)",
      "CREATE INDEX artifacts_blob ON artifacts (blob_hash)",
      """
      CREATE TABLE pointers (
        id TEXT PRIMARY KEY,
        release_id TEXT,
        rollout INTEGER NOT NULL DEFAULT 100,
        updated_at TEXT NOT NULL
      )
      """,
      """
      CREATE TABLE promotions (
        id TEXT PRIMARY KEY,
        release_id TEXT,
        from_release_id TEXT,
        rollout INTEGER NOT NULL,
        kind TEXT NOT NULL,
        reason TEXT,
        inserted_at TEXT NOT NULL
      )
      """,
      "CREATE INDEX promotions_inserted_at ON promotions (inserted_at)"
    ]
  end
end
