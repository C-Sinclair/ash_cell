defmodule AshCell.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/C-Sinclair/ash_cell"

  @description """
  Database-per-tenant SQLite for the Ash Framework — each tenant is one
  encrypted file, owned by one process at a time, replicated to object storage.
  """

  def project do
    [
      app: :ash_cell,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),

      # Hex
      description: @description,
      package: package(),

      # Docs
      name: "AshCell",
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp package do
    [
      name: "ash_cell",
      maintainers: ["Conor Sinclair"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Ash Framework" => "https://ash-hq.org"
      },
      files:
        ~w[lib .formatter.exs mix.exs README* LICENSE* CHANGELOG* CONTRIBUTING* docs usage-rules.md]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extra_section: "GUIDES",
      extras: [
        {"README.md", title: "Home"},
        {"CHANGELOG.md", title: "Changelog"},
        "docs/spec.md",
        "docs/dst.md",
        {"CONTRIBUTING.md", title: "Contributing"}
      ],
      groups_for_modules: [
        "Getting started": [AshCell, AshCell.Resource, AshCell.Migrator],
        "Integration points": [
          AshCell.Binder,
          AshCell.CellKey,
          AshCell.Job,
          AshCell.LiveView,
          AshCell.Plug.OwnerRouting
        ],
        "Replication and ownership": [
          AshCell.Lease,
          AshCell.ObjectStore,
          AshCell.Ownership,
          AshCell.Replicator,
          AshCell.SnapshotPolicy
        ],
        Internals: ~r/.*/
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.31"},
      # A fork, not a preference: upstream cannot express database-per-tenant.
      # See the Requirements section of the README. Resolved from the sibling
      # checkout when there is one, so edits there are picked up on the next
      # compile, and from git otherwise, so a standalone clone builds.
      {:ash_sqlite, ash_sqlite_dep()},
      {:ecto_sqlite3, "~> 0.12"},
      {:ecto_sql, "~> 3.13"},
      {:jason, "~> 1.0"},
      # Optional: only needed by AshCell.LiveView and AshCell.Plug.OwnerRouting.
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:plug, "~> 1.16", optional: true},
      {:req, "~> 0.5"},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp ash_sqlite_dep do
    if File.dir?("../ash_sqlite") do
      [path: "../ash_sqlite", override: true]
    else
      # Pinned to a ref, not a branch. CI has no sibling checkout, so this is what
      # it builds against, and tracking the fork's default branch meant a push
      # there could turn this repo's CI red with no commit here to explain it.
      # Bump deliberately when the fork gains something this repo needs.
      [
        github: "C-Sinclair/ash_sqlite",
        ref: "3defa128fcdbc5b6bea71dcbf3d3c1e3e317d501",
        override: true
      ]
    end
  end

  defp aliases do
    [
      # Fails loudly if exqlite was compiled without SQLCipher — a missing
      # EXQLITE_USE_SYSTEM at dep-compile time silently yields plain SQLite
      # that cannot open an encrypted database.
      "cipher.check": &AshCell.MixProject.cipher_check/1
    ]
  end

  @doc false
  def cipher_check(_) do
    Mix.Task.run("app.start")

    case Exqlite.Sqlite3.open(":memory:") do
      {:ok, db} ->
        case cipher_version(db) do
          {:ok, [[version]]} when is_binary(version) and version != "" ->
            Mix.shell().info("SQLCipher available: #{version}")

          _ ->
            Mix.raise("""
            exqlite is not linked against SQLCipher.

            Rebuild with:
              export EXQLITE_USE_SYSTEM=1
              export EXQLITE_SYSTEM_CFLAGS=-I$(brew --prefix sqlcipher)/include/sqlcipher
              export EXQLITE_SYSTEM_LDFLAGS="-L$(brew --prefix sqlcipher)/lib -lsqlcipher"
              mix deps.compile exqlite --force
            """)
        end

      {:error, reason} ->
        Mix.raise("could not open in-memory database: #{inspect(reason)}")
    end
  end

  # PRAGMA cipher_version only exists under SQLCipher; on plain SQLite the
  # statement will not even prepare, which is the signal we want.
  defp cipher_version(db) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "PRAGMA cipher_version") do
      Exqlite.Sqlite3.fetch_all(db, stmt)
    end
  end
end
