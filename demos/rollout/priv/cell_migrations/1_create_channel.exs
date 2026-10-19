defmodule Rollout.CellMigrations.CreateChannel do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE releases (
      id TEXT PRIMARY KEY,
      version TEXT NOT NULL,
      notes TEXT,
      state TEXT NOT NULL DEFAULT 'draft',
      inserted_at TEXT NOT NULL
    )
    """)

    execute("CREATE UNIQUE INDEX releases_version ON releases (version)")

    execute("""
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
    """)

    # The resolve path's index: release first, then the client facets it
    # filters on. Ordered to match the query so it is a range scan, not a scan
    # plus a filter.
    execute("CREATE INDEX artifacts_resolve ON artifacts (release_id, platform, arch, min_runtime)")

    execute("CREATE INDEX artifacts_blob ON artifacts (blob_hash)")

    execute("""
    CREATE TABLE pointers (
      id TEXT PRIMARY KEY,
      release_id TEXT,
      rollout INTEGER NOT NULL DEFAULT 100,
      updated_at TEXT NOT NULL
    )
    """)

    execute("""
    CREATE TABLE promotions (
      id TEXT PRIMARY KEY,
      release_id TEXT,
      from_release_id TEXT,
      rollout INTEGER NOT NULL,
      kind TEXT NOT NULL,
      reason TEXT,
      inserted_at TEXT NOT NULL
    )
    """)

    execute("CREATE INDEX promotions_inserted_at ON promotions (inserted_at)")
  end
end
