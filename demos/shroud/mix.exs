defmodule Shroud.MixProject do
  use Mix.Project

  def project do
    [
      app: :shroud,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Shroud.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:ash, "~> 3.31"},
      {:ash_postgres, "~> 2.11"},
      {:ash_sqlite, path: "../../../ash_sqlite", override: true},
      {:ash_cell, path: "../.."},
      {:ecto_sqlite3, "~> 0.12"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      # TODO bump on release to {:phoenix_live_view, "~> 1.0.0"},
      {:phoenix_live_view, "~> 1.0.0-rc.1", override: true},
      {:floki, ">= 0.30.0", only: :test},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
      {:bandit, "~> 1.5"},
      {:wax_, "~> 0.6"},
      {:cbor, "~> 1.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind shroud", "esbuild shroud"],
      "assets.deploy": [
        "tailwind shroud --minify",
        "esbuild shroud --minify",
        "phx.digest"
      ],
      # Fails loudly if exqlite was compiled without SQLCipher. A missing
      # EXQLITE_USE_SYSTEM at dep-compile time silently yields plain SQLite, and the
      # first symptom is otherwise `zero_knowledge_test` finding plaintext in a cell
      # file -- a real failure, but one that reads as a crypto bug rather than a build
      # one. Duplicated from the library's own mix.exs because it is an alias there
      # rather than a task, so there is nothing to call.
      "cipher.check": &Shroud.MixProject.cipher_check/1
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

  # PRAGMA cipher_version only exists under SQLCipher; on plain SQLite the statement
  # will not even prepare, which is the signal we want.
  defp cipher_version(db) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "PRAGMA cipher_version") do
      Exqlite.Sqlite3.fetch_all(db, stmt)
    end
  end
end
