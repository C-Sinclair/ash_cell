defmodule Region.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Region.GlobalRepo,
      {Region.CellRepo, tenants: Region.Stores.fleet_config()}
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Region.Supervisor) do
      :ok = Region.Accounts.migrate()
      {:ok, pid}
    end
  end
end
