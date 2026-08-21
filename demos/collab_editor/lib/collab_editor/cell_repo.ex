defmodule CollabEditor.CellRepo do
  @moduledoc """
  Template repo for a document's cell.

  One instance per document, each attached to that document's own encrypted SQLite
  file. The module is never used to run a query directly — `AshCell.Binder` asks
  for the right instance once per statement, from the process about to issue it.

  `pool_size: 1` is deliberate: a document has exactly one connection, so
  concurrent writers queue in the pool and reach SQLite one at a time. That is
  where the total order over edits comes from, and it is free.
  """
  use AshSqlite.Repo, otp_app: :collab_editor

  def installed_extensions, do: []
end
