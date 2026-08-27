defmodule Relay.CellRepo do
  @moduledoc """
  The repo *module* every channel cell is an instance of.

  A cell starts `start_link(name: nil, database: <channel>.db)` against this
  module, so the module is a template and the pid is the binding.
  """
  use AshSqlite.Repo, otp_app: :relay

  def installed_extensions, do: []
end
