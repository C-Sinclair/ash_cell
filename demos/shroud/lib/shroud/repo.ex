defmodule Shroud.Repo do
  @moduledoc """
  The **global** database: one shared Postgres holding data that is not owned by
  any single clinic — the clinic registry itself, and anything cross-tenant.

  Clinical data does not live here. It lives in per-clinic SQLite cells.
  """
  use AshPostgres.Repo, otp_app: :shroud

  def installed_extensions, do: ["ash-functions"]
  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
end
