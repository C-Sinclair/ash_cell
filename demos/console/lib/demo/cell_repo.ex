defmodule Demo.CellRepo do
  @moduledoc """
  Template repo for **tenanted** data.

  One instance of this repo is started per clinic, each attached to that clinic's
  own encrypted SQLite file. The module is never used directly to run a query.
  `use AshCell.Repo` makes it a tenant repo, so the data layer asks it for the
  right instance once per statement; `AshCell.with_tenant/2` binds one by hand for
  code that does not go through a resource.
  """
  use AshCell.Repo, otp_app: :demo

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}

  # Each cell's own key, from the cell key AshCell starts the instance with. A
  # revoked key is nil, which the encrypted fleet refuses to open.
  def init(context, config) do
    super(context, Keyword.put(config, :key, Demo.Cells.Vault.key_for(config[:tenant])))
  end
end
