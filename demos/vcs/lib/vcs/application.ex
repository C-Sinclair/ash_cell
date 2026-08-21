defmodule Vcs.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    store = object_store()

    children = [
      {AshCell,
       repo: Vcs.CellRepo,
       dir: Application.get_env(:vcs, :cell_dir, "priv/cells"),
       max_resident: 64,
       key_for: &Vcs.Vault.key_for/1,
       migrator: Vcs.Cells.Schema,
       store: store},
      # After AshCell, so a sweep never runs before the fleet it sweeps exists.
      {Vcs.Snapshotter,
       store: store, interval_ms: Application.get_env(:vcs, :snapshot_interval_ms, 60_000)},
      VcsWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Vcs.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    VcsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Replication is optional: without a configured bucket the fleet runs local-only, which is
  # what the test suite and a bare `mix phx.server` want.
  defp object_store do
    case Application.get_env(:vcs, :object_store) do
      nil -> nil
      opts -> AshCell.ObjectStore.new(opts)
    end
  end
end
