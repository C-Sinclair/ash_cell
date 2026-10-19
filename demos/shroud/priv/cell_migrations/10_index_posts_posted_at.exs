defmodule Shroud.CellMigrations.IndexPostsPostedAt do
  use Ecto.Migration

  def up do
    # A timeline reads a page of ids and sorts by time, so both get an index.
    execute("CREATE INDEX posts_posted_at ON posts(posted_at DESC)")
  end
end
