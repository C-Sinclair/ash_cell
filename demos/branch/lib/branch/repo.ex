defmodule Branch.CellRepo do
  @moduledoc """
  The repo *module* every branch's cell is an instance of.

  A cell starts `start_link(name: nil, database: <key>.db)` against this module, so
  the module is a template and the pid is the binding.
  """
  use AshSqlite.Repo, otp_app: :branch

  def installed_extensions, do: []
end

defmodule Branch.CatalogRepo do
  @moduledoc """
  The control plane's own database, on its own repo module.

  Its own module is not tidiness. Ecto's dynamic binding is per repo *module*
  (`{repo_module, :dynamic_repo}` in the process dictionary), so a shared table
  living on `Branch.CellRepo` would silently inherit whichever cell the calling
  process happens to have bound — and the catalog would write rows describing a
  branch *into* that branch. A separate module is immune by construction. See
  [ADR-06](../../../docs/decisions/ADR-06-own-repo-for-shared-tables.md).

  It is deliberately not a cell. The catalog is the one thing in this demo that must
  be readable without first knowing which cell to open.
  """
  use Ecto.Repo, otp_app: :branch, adapter: Ecto.Adapters.SQLite3
end
