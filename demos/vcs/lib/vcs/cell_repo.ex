defmodule Vcs.CellRepo do
  @moduledoc """
  Template repo for a repository cell.

  One instance is started per repository, attached to that repository's own encrypted SQLite
  file. The module is never queried directly: `AshCell.Resource` binds the right instance into
  whichever process is about to issue a statement.
  """
  use AshSqlite.Repo, otp_app: :vcs

  def installed_extensions, do: []
end
