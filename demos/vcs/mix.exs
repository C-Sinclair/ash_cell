defmodule Vcs.MixProject do
  use Mix.Project

  def project do
    [
      app: :vcs,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Vcs.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    [
      # Fails loudly if exqlite was compiled without SQLCipher. A missing EXQLITE_USE_SYSTEM at
      # dep-compile time silently yields plain SQLite that cannot open an encrypted database,
      # and this assertion is the only thing that catches it.
      "cipher.check": &Vcs.MixProject.cipher_check/1
    ]
  end

  @doc false
  def cipher_check(_) do
    Mix.Task.run("app.start")

    with {:ok, db} <- Exqlite.Sqlite3.open(":memory:"),
         {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "PRAGMA cipher_version"),
         {:ok, [[version]]} when is_binary(version) and version != "" <-
           Exqlite.Sqlite3.fetch_all(db, stmt) do
      Mix.shell().info("SQLCipher available: " <> version)
    else
      _ ->
        Mix.raise("""
        exqlite is not linked against SQLCipher, so cells would be unencrypted.

        Rebuild with:
          source .envrc
          mix deps.compile exqlite --force
        """)
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.31"},
      {:ash_sqlite, path: "../../../ash_sqlite", override: true},
      {:ash_cell, path: "../.."},
      {:ecto_sqlite3, "~> 0.12"},
      {:phoenix, "~> 1.7.14"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
