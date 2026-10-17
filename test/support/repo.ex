defmodule AshCell.TestRepo do
  @moduledoc """
  A single repo *module* whose instances are started once per cell.

  Every cell runs `start_link(name: nil, database: cell_path)` against this
  module, so the module is a template and the pid is the cell binding.
  """
  use AshCell.Repo, otp_app: :ash_cell

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end

defmodule AshCell.TestGlobalRepo do
  @moduledoc """
  A repo *module* started under its own name, for resources that are not cells.

  Separate from `AshCell.TestRepo` on purpose, and AshSqlite insists on it: a
  tenant repo serves `strategy :context` resources only. Ecto keys the dynamic
  binding as `{repo_module, :dynamic_repo}`, so a cell binding on one module
  cannot reach another — which is what makes a shared table safe to keep alongside
  cells.
  """
  use AshSqlite.Repo, otp_app: :ash_cell

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
  def write_transactions?, do: true
end

defmodule AshCell.TestProbeRepo do
  @moduledoc """
  A plain repo module whose instances `AshCell.ProbeTest` starts and binds by hand.

  Not a tenant repo, so it can carry `AshCell.Test.Patient`, which has no
  multitenancy: the probe is about what Ecto's dynamic binding does on its own,
  with nothing of AshCell or the data layer choosing the instance.
  """
  use AshSqlite.Repo, otp_app: :ash_cell

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end
