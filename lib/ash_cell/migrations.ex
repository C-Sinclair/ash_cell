defmodule AshCell.Migrations do
  @moduledoc """
  Per-cell schema migration, from Ecto migration files.

  A cell is migrated when it opens, before it serves anything, with the files in the
  fleet's `migrations_path`: `<version>_<name>.exs`, each defining an
  `Ecto.Migration`, the layout `AshSqlite.MultiTenancy` reads. A cell whose
  migration raises does not open, and is quarantined, because serving a
  half-migrated schema is worse than being down.

  ## Why lazy migration is not a free lunch

  There is no moment at which the whole fleet shares a schema. A migration that
  works for 900 clinics and fails on the 901st takes down that clinic alone, at
  whatever hour it next wakes up, so `mix ash_cell.migrate` walks every tenant at
  deploy time while someone is watching. Application code must tolerate a version
  window, since a cell opened before a deploy stays at the old version until it
  next opens.

  ## Cells migrated by `AshCell.Migrator`

  A cell from before this module recorded its version in `PRAGMA user_version`
  rather than in `schema_migrations`. On first open, such a cell records every
  migration up to that version as already run, so give each old migration the same
  version number as a file: `1_create_patients.exs` for `migration 1`.
  """

  require Logger

  @type migration :: {non_neg_integer(), module()}

  @doc """
  Compiles the migration files under `path`, sorted by version.

  A file that is already loaded is not compiled again. A fleet that restarts, or two
  fleets sharing a path, would otherwise redefine a module a running migration may
  be executing.
  """
  @spec compile(Path.t() | nil) :: [migration()]
  def compile(nil), do: []

  # `Ecto.Migrator`'s naming rules: `<version>_<name>.exs`.
  def compile(path) do
    [path, "**", "*.exs"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case Integer.parse(Path.basename(file)) do
        {version, "_" <> _} -> [{version, migration_module!(file)}]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  defp migration_module!(file) do
    modules =
      case Code.require_file(file) do
        nil -> modules_compiled_from(file)
        compiled -> Enum.map(compiled, &elem(&1, 0))
      end

    Enum.find(modules, &function_exported?(&1, :__migration__, 0)) ||
      raise Ecto.MigrationError,
            "file #{Path.relative_to_cwd(file)} does not define an Ecto.Migration"
  end

  defp modules_compiled_from(file) do
    source = file |> Path.expand() |> String.to_charlist()

    for {module, _} <- :code.all_loaded(),
        module.module_info(:compile)[:source] == source,
        do: module
  end

  @doc """
  Runs every migration the cell open on `repo_pid` has not run.

  Returns `{:ok, version}`, the highest version the cell has run, or
  `{:error, {:migration_failed, version, exception}}` naming the first migration
  that did not run. Each migration is its own transaction, so a failure leaves
  the earlier ones applied.
  """
  @spec run(module(), pid(), [migration()]) ::
          {:ok, non_neg_integer()} | {:error, {:migration_failed, integer(), module()}}
  def run(_repo, _repo_pid, []), do: {:ok, 0}

  def run(repo, repo_pid, migrations) do
    adopt_user_version(repo, repo_pid, migrations)
    Ecto.Migrator.run(repo, migrations, :up, all: true, dynamic_repo: repo_pid, log: false)
    {:ok, current_version(repo, repo_pid)}
  rescue
    error ->
      ran = migrated_versions(repo, repo_pid)
      {version, _} = Enum.find(migrations, {nil, nil}, fn {v, _} -> v not in ran end)

      # Deliberately no tenant data in the message; a migration failure is about
      # schema, and the version is what says which tenants are stuck where.
      Logger.error("cell migration #{version} raised: #{inspect(error.__struct__)}")
      {:error, {:migration_failed, version, error.__struct__}}
  end

  @doc "The highest migration version the cell open on `repo_pid` has run, or 0."
  @spec current_version(module(), pid()) :: non_neg_integer()
  def current_version(repo, repo_pid) do
    repo |> migrated_versions(repo_pid) |> Enum.max(fn -> 0 end)
  end

  defp migrated_versions(repo, repo_pid),
    do: Ecto.Migrator.migrated_versions(repo, dynamic_repo: repo_pid, log: false)

  # Only once: after this the cell has a `schema_migrations` table, and the
  # `user_version` it was carrying is not read again.
  defp adopt_user_version(repo, repo_pid, migrations) do
    with false <- schema_migrations?(repo_pid),
         version when version > 0 <- user_version(repo_pid) do
      # Creates the table, as any read of it does.
      _ = migrated_versions(repo, repo_pid)

      now =
        NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

      for {v, _module} <- migrations, v <= version do
        Ecto.Adapters.SQL.query!(
          repo_pid,
          "INSERT OR IGNORE INTO schema_migrations (version, inserted_at) VALUES (?, ?)",
          [v, now]
        )
      end
    end

    :ok
  end

  defp schema_migrations?(repo_pid) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo_pid,
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'",
        []
      )

    rows != []
  end

  defp user_version(repo_pid) do
    %{rows: [[version]]} = Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA user_version", [])
    version
  end
end
