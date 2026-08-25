defmodule Branch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BranchWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:branch, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Branch.PubSub},
      Branch.CatalogRepo,
      # Start a worker by calling: Branch.Worker.start_link(arg)
      # {Branch.Worker, arg},
      # Start to serve requests, typically the last entry
      {AshCell, Branch.Cells.config()},
      BranchWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Branch.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # The catalog is the control plane's own database, not a cell, so nothing in
      # the cell runtime migrates it.
      :ok = Branch.Catalog.migrate()
      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BranchWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
