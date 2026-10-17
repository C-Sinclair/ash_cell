defmodule Vcs.CellRepo do
  @moduledoc """
  Template repo for a repository cell.

  One instance is started per repository, attached to that repository's own encrypted SQLite
  file. The module is never queried directly. `use AshCell.Repo` makes it a tenant repo, so the
  data layer asks it for the right instance in whichever process is about to issue a statement.
  """
  use AshCell.Repo, otp_app: :vcs

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end
