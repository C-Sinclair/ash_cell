defmodule AshCell.Supervisor do
  @moduledoc "Supervision tree for a cell fleet: registry, cell supervisor, manager."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      AshCell.Registry,
      AshCell.Holders,
      AshCell.ReadCache,
      {DynamicSupervisor, name: AshCell.CellSupervisor, strategy: :one_for_one},
      {AshCell.Manager, opts},
      # Last in the list, so it is first to terminate: cells are still alive and
      # the manager is still answering while the drain runs.
      {AshCell.Drain, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
