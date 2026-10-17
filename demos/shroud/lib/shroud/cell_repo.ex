defmodule Shroud.CellRepo do
  @moduledoc """
  Template repo for **tenanted** data.

  One instance of this repo is started per clinic, each attached to that clinic's
  own encrypted SQLite file. The module is never used directly to run a query.
  `use AshCell.Repo` makes it a tenant repo, so the data layer asks it for the
  right instance once per statement; `AshCell.with_tenant/2` binds one by hand for
  code that does not go through a resource.
  """
  use AshCell.Repo, otp_app: :shroud

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end
