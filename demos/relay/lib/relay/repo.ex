defmodule Relay.CellRepo do
  @moduledoc """
  The repo *module* every channel cell is an instance of.

  A cell starts `start_link(name: nil, database: <channel>.db)` against this
  module, so the module is a template and the pid is the binding.
  """
  use AshCell.Repo, otp_app: :relay

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end
