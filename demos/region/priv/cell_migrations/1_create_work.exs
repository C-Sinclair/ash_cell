defmodule Region.CellMigrations.CreateWork do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE projects (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      region TEXT NOT NULL
    )
    """)

    execute("""
    CREATE TABLE tasks (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES projects (id),
      title TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'open'
    )
    """)
  end
end
