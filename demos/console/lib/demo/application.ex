defmodule Demo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DemoWeb.Telemetry,
      Demo.Repo,
      Demo.Cells.Vault,
      {AshCell,
       repo: Demo.CellRepo,
       dir: Application.get_env(:demo, :cell_dir, "priv/cells"),
       max_resident: 64,
       key_for: &Demo.Cells.Vault.key_for/1,
       migrator: Demo.Cells.Schema},
      {DNSCluster, query: Application.get_env(:demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Demo.PubSub},
      # Start a worker by calling: Demo.Worker.start_link(arg)
      # {Demo.Worker, arg},
      # Start to serve requests, typically the last entry
      DemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Demo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
