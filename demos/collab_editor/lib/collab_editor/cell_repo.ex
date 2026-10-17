defmodule CollabEditor.CellRepo do
  @moduledoc """
  Template repo for a document's cell.

  One instance per document, each attached to that document's own encrypted SQLite
  file. The module is never used to run a query directly. `use AshCell.Repo` makes
  it a tenant repo, so the data layer asks it for the right instance once per
  statement, from the process about to issue it.

  `pool_size: 1` is deliberate: a document has exactly one connection, so
  concurrent writers queue in the pool and reach SQLite one at a time. That is
  where the total order over edits comes from, and it is free.
  """
  use AshCell.Repo, otp_app: :collab_editor

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end
