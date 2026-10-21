defmodule Region.MixProject do
  use Mix.Project

  def project do
    [
      app: :region,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Region.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.33 and >= 3.33.2"},
      {:ash_sqlite,
       github: "ash-project/ash_sqlite", ref: "a8aaad346bbe0acc7464acacc1235e9c83c88845"},
      {:ash_cell, path: "../.."},
      {:ecto_sqlite3, "~> 0.12"}
    ]
  end
end
