defmodule AshCell.Repo do
  @moduledoc """
  An `AshSqlite.Repo` whose instances are cells, started from the repo's own place in
  the supervision tree.

  It is configured and started the way `AshSqlite.MultiTenancy` is: the fleet's
  options sit under the repo's `tenants:` key, and each cell's instance is started
  with `tenant:` set to its cell key, so `init/2` can give each cell its own key. An
  `encrypted?: true` fleet refuses a cell whose `init/2` set no `:key`, so set it
  before calling `super/2`. Cells run with `synchronous: :full` unless the repo's
  config or `init/2` sets another level.

      config :my_app, MyApp.CellRepo,
        tenants: [
          dir: "/data/cells",
          migrations_path: "priv/cell_migrations",
          encrypted?: true
        ]

      defmodule MyApp.CellRepo do
        use AshCell.Repo, otp_app: :my_app

        def init(context, config) do
          super(context, Keyword.put(config, :key, MyApp.Vault.key_for(config[:tenant])))
        end
      end

      children = [MyApp.CellRepo]
  """

  defmacro __using__(opts) do
    quote do
      use AshSqlite.Repo, unquote(opts)

      @ash_cell_otp_app Keyword.fetch!(unquote(opts), :otp_app)

      # `init/2` is overridable already, from `use AshSqlite.Repo`; Ecto's
      # `child_spec/1` is not.
      defoverridable child_spec: 1

      def child_spec(opts), do: AshCell.Repo.child_spec(__MODULE__, @ash_cell_otp_app, opts)

      # The cell key is read before `super/2`, because AshSqlite's own init/2 drops
      # `:tenant` before returning.
      def init(context, config) do
        cell_key = config[:tenant]

        with {:ok, config} <- super(context, config) do
          AshCell.Repo.check_init(config, cell_key)
        end
      end

      def tenant_repo(tenant, context), do: AshCell.Binder.tenant_repo(tenant, context)

      def write_transactions?, do: true

      @doc false
      def __ash_cell_otp_app__, do: @ash_cell_otp_app

      defoverridable child_spec: 1, init: 2, tenant_repo: 2, write_transactions?: 0
    end
  end

  @doc false
  def child_spec(repo, otp_app, opts) do
    tenants =
      otp_app
      |> Application.get_env(repo, [])
      |> Keyword.get(:tenants, [])
      |> Keyword.merge(Keyword.get(opts, :tenants, []))

    if tenants == [] do
      raise ArgumentError, """
      #{inspect(repo)} is a cell repo, so starting it starts its cells, and it has \
      no `tenants:` configuration to start them with:

          config #{inspect(otp_app)}, #{inspect(repo)}, tenants: [dir: "priv/cells"]
      """
    end

    Supervisor.child_spec({AshCell, Keyword.put(tenants, :repo, repo)}, id: repo)
  end

  @doc false
  def check_init(config, cell_key) do
    if config[:encrypted?] && is_nil(config[:key]) do
      # Raised rather than defaulted. SQLite creates a plaintext file for a cell
      # opened with no key, so the failure would be silent and the file on disk
      # would be unencrypted under a fleet that says it is not.
      raise ArgumentError, """
      cell #{inspect(cell_key)} belongs to an `encrypted?: true` fleet, but \
      the repo's init/2 gave it no `:key`. Set it from `config[:tenant]` before \
      calling super/2.
      """
    end

    # A nil key means no key, not an empty one: exqlite would issue `PRAGMA key`
    # with nothing after it.
    config = if is_nil(config[:key]), do: Keyword.delete(config, :key), else: config

    # :full unless the repo's config or init/2 chose a level. Under exqlite's default,
    # :normal, a power cut loses acknowledged commits (ADR-20).
    config = Keyword.put_new(config, :synchronous, :full)

    {:ok, Keyword.drop(config, [:tenant, :tenants, :encrypted?])}
  end
end
