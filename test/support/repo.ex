defmodule AshCell.TestRepo do
  @moduledoc """
  A single repo *module* whose instances are started once per tenant.

  Every cell runs `start_link(name: nil, database: tenant_path)` against this
  module, so the module is a template and the pid is the tenant binding.
  """
  use AshSqlite.Repo, otp_app: :ash_cell

  def installed_extensions, do: []
end
