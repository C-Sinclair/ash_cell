defmodule AshCell.Repo do
  @moduledoc """
  An `AshSqlite.Repo` whose instances are cells.

      defmodule MyApp.CellRepo do
        use AshCell.Repo, otp_app: :my_app
      end

  Takes the same options as `use AshSqlite.Repo`, and defines the two callbacks
  that make a repo module a cell repo:

    * `c:AshSqlite.Repo.tenant_repo/2`, answered by `AshCell.Binder.tenant_repo/2`,
      which makes the module a tenant repo: the data layer asks it for a tenant's
      repo instance once per statement
    * `c:AshSqlite.Repo.write_transactions?/0` as `true`, so Ash wraps a multi-step
      action in one transaction instead of leaving a failed one half-applied

  Both can be overridden. A tenant repo serves `strategy :context` resources only,
  and AshSqlite refuses anything else at compile time, so a table shared across
  cells goes on a repo module of its own.
  """

  defmacro __using__(opts) do
    quote do
      use AshSqlite.Repo, unquote(opts)

      def tenant_repo(tenant, context), do: AshCell.Binder.tenant_repo(tenant, context)

      def write_transactions?, do: true

      defoverridable tenant_repo: 2, write_transactions?: 0
    end
  end
end
