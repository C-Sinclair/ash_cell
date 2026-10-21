defmodule Region.CellRepo do
  @moduledoc """
  The repo module every organisation's and project's cell is an instance of.
  """
  use AshCell.Repo, otp_app: :region

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end

defmodule Region.GlobalRepo do
  @moduledoc """
  The global store holding `Region.Accounts.Org`, on its own repo module.

  A separate module keeps the org table out of whatever cell the calling process has
  bound, because Ecto's dynamic binding is per repo module. See
  [ADR-06](../../../docs/decisions/ADR-06-own-repo-for-shared-tables.md).
  """
  use AshSqlite.Repo, otp_app: :region

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end
