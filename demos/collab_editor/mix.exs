defmodule CollabEditor.MixProject do
  use Mix.Project

  def project do
    [
      app: :collab_editor,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {CollabEditor.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:ash, "~> 3.31"},
      {:ash_sqlite, path: "../../../ash_sqlite", override: true},
      {:ash_cell, path: "../.."},
      {:ecto_sqlite3, "~> 0.12"},
      {:ecto_sql, "~> 3.10"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0.0-rc.1", override: true},
      {:floki, ">= 0.30.0", only: :test},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:y_ex, "~> 0.10.5"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:bandit, "~> 1.5"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets npm install"
      ],
      "assets.build": ["tailwind collab_editor", "esbuild collab_editor"],
      # Needs a server already running; see test/browser/convergence.mjs.
      "browser.test": ["cmd node test/browser/convergence.mjs"],
      "assets.deploy": [
        "tailwind collab_editor --minify",
        "esbuild collab_editor --minify",
        "phx.digest"
      ]
    ]
  end
end
