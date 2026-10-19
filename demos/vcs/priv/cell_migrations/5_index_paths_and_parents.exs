defmodule Vcs.CellMigrations.IndexPathsAndParents do
  use Ecto.Migration

  def up do
    execute("CREATE INDEX commit_paths_path ON commit_paths(path)")

    execute("CREATE INDEX commits_parent ON commits(parent_id)")
  end
end
