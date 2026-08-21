defmodule Demo.CellRepo do
  @moduledoc """
  Template repo for **tenanted** data.

  One instance of this repo is started per clinic, each attached to that clinic's
  own encrypted SQLite file. The module is never used directly to run a query;
  `AshCell.with_tenant/2` binds the right instance into the calling process.
  """
  use AshSqlite.Repo, otp_app: :demo

  def installed_extensions, do: []
end
