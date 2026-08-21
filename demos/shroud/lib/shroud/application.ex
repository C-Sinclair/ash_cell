defmodule Shroud.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ShroudWeb.Telemetry,
      Shroud.Repo,
      Shroud.Cells.Vault,
      Shroud.Auth.ChallengeStore,
      {AshCell,
       repo: Shroud.CellRepo,
       dir: Application.get_env(:shroud, :cell_dir, "priv/cells"),
       max_resident: Application.get_env(:shroud, :max_resident, 64),
       key_for: &Shroud.Cells.Vault.key_for/1,
       migrator: Shroud.Cells.Schema},
      {DNSCluster, query: Application.get_env(:shroud, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Shroud.PubSub},
      # Start a worker by calling: Shroud.Worker.start_link(arg)
      # {Shroud.Worker, arg},
      # Start to serve requests, typically the last entry
      ShroudWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Shroud.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ShroudWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
