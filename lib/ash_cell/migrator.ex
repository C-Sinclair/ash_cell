defmodule AshCell.Migrator do
  @moduledoc """
  Per-cell schema migration.

  A cell is migrated when it activates, before it serves anything. `PRAGMA
  user_version` records where a cell has got to, and any migrations above that
  number run in order.

  ## Why lazy migration is not a free lunch

  There is no moment at which the whole fleet shares a schema. That is the price
  of a database per tenant, and it has to be designed for rather than discovered:

    * **Blast radius is one tenant.** A migration that works for 900 clinics and
      fails on the 901st takes down that clinic alone. Good — but it happens at
      whatever hour that tenant next wakes up, with nobody watching, so migration
      failure has to be *observable*, not just survivable. Hence quarantine.
    * **Application code must tolerate a version window.** Cells activated before
      a deploy sit at the old version until they next start.
    * **Eager beats lazy for a known fleet.** `mix ash_cell.migrate` walks every
      tenant at deploy time so failures surface while someone is looking. Lazy is
      the fallback for tenants that were not in the list, not the primary path.

  ## Failing closed

  A cell whose migration raises does not start. It is recorded as quarantined and
  its tenant gets an error rather than a database in an unknown state. Serving a
  half-migrated schema is worse than being down, because the damage is silent.

  ## Defining migrations

      defmodule MyApp.CellMigrations do
        use AshCell.Migrator

        migration 1, \"\"\"
        CREATE TABLE patients (id TEXT PRIMARY KEY, name TEXT NOT NULL)
        \"\"\"

        migration 2, fn repo_pid ->
          Ecto.Adapters.SQL.query!(repo_pid, "ALTER TABLE patients ADD COLUMN mrn TEXT", [])
        end
      end

  SQLite runs DDL transactionally, and each migration is wrapped in its own
  transaction, so a failure inside one leaves that migration's statements rolled
  back rather than half-applied. A migration containing several statements should
  therefore be one entry, not several.
  """

  @type step :: {pos_integer(), String.t() | (pid() -> any())}

  @callback migrations() :: [step()]

  defmacro __using__(_opts) do
    quote do
      @behaviour AshCell.Migrator
      Module.register_attribute(__MODULE__, :ash_cell_versions, accumulate: true)
      import AshCell.Migrator, only: [migration: 2]
      @before_compile AshCell.Migrator
    end
  end

  @doc """
  Declares a migration at `version`.

  The body is compiled into a function clause rather than stored in a module
  attribute, because an attribute cannot hold an anonymous function — only
  literals and remote function captures survive `@attr` escaping.
  """
  defmacro migration(version, body) do
    quote do
      @ash_cell_versions unquote(version)
      def __migration__(unquote(version)), do: unquote(body)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @impl AshCell.Migrator
      def migrations do
        @ash_cell_versions
        |> Enum.sort()
        |> Enum.map(&{&1, __migration__(&1)})
      end

      @doc "Highest version this module defines."
      def target_version do
        case @ash_cell_versions do
          [] -> 0
          versions -> Enum.max(versions)
        end
      end

      @doc false
      def run(repo_pid), do: AshCell.Migrator.run(repo_pid, migrations())
    end
  end

  @doc "Current schema version of an open cell."
  def current_version(repo_pid) do
    %{rows: [[version]]} = Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA user_version", [])
    version
  end

  @doc """
  Applies every migration above the cell's current version, in order.

  Returns `{:ok, version}` with the version it reached, or `{:error, reason}`
  naming the migration that failed — the version number matters far more than the
  exception when you are working out which tenants are stuck and where.
  """
  def run(repo_pid, steps) do
    from = current_version(repo_pid)

    steps
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.filter(fn {version, _} -> version > from end)
    |> Enum.reduce_while({:ok, from}, fn {version, body}, {:ok, _} ->
      case apply_step(repo_pid, version, body) do
        :ok -> {:cont, {:ok, version}}
        {:error, reason} -> {:halt, {:error, {:migration_failed, version, reason}}}
      end
    end)
  end

  defp apply_step(repo_pid, version, body) do
    Ecto.Adapters.SQL.query!(repo_pid, "BEGIN", [])

    try do
      case body do
        sql when is_binary(sql) -> Ecto.Adapters.SQL.query!(repo_pid, sql, [])
        fun when is_function(fun, 1) -> fun.(repo_pid)
      end

      Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA user_version = #{version}", [])
      Ecto.Adapters.SQL.query!(repo_pid, "COMMIT", [])
      :ok
    rescue
      error ->
        safe_rollback(repo_pid)
        {:error, error}
    end
  end

  defp safe_rollback(repo_pid) do
    Ecto.Adapters.SQL.query!(repo_pid, "ROLLBACK", [])
  rescue
    _ -> :ok
  end

  @doc false
  def normalise(nil), do: {:none, 0}

  def normalise(module) when is_atom(module) do
    {{:module, module}, module.target_version()}
  end

  # A bare function is still supported for simple cases and for tests, but it
  # carries no version, so every activation re-runs it.
  def normalise(fun) when is_function(fun, 1), do: {{:fun, fun}, :unversioned}

  @doc false
  def apply_to(_repo_pid, {:none, _}), do: {:ok, 0}

  def apply_to(repo_pid, {{:module, module}, _}), do: run(repo_pid, module.migrations())

  def apply_to(repo_pid, {{:fun, fun}, _}) do
    fun.(repo_pid)
    {:ok, current_version(repo_pid)}
  end
end
