defmodule Rollout.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RolloutWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:rollout, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Rollout.PubSub},
      # Start a worker by calling: Rollout.Worker.start_link(arg)
      # {Rollout.Worker, arg},
      # Start to serve requests, typically the last entry
      {AshCell, Rollout.Cells.config()},
      RolloutWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rollout.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RolloutWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
