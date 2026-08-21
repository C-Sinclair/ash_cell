defmodule AshCell.TestRepo do
  @moduledoc """
  A single repo *module* whose instances are started once per tenant.

  Every cell runs `start_link(name: nil, database: tenant_path)` against this
  module, so the module is a template and the pid is the tenant binding.
  """
  use AshSqlite.Repo, otp_app: :ash_cell

  def installed_extensions, do: []
end

defmodule AshCell.TestGlobalRepo do
  @moduledoc """
  A repo *module* started under its own name, for resources that are not cells.

  Separate from `AshCell.TestRepo` on purpose. Ecto keys the dynamic binding as
  `{repo_module, :dynamic_repo}`, so a cell binding on one module cannot reach
  another — which is what makes a shared table safe to keep alongside cells.
  """
  use AshSqlite.Repo, otp_app: :ash_cell

  def installed_extensions, do: []
end
