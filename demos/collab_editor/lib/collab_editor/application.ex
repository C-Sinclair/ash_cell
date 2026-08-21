defmodule CollabEditor.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CollabEditorWeb.Telemetry,
      {Phoenix.PubSub, name: CollabEditor.PubSub},
      CollabEditorWeb.Presence,
      {AshCell,
       repo: CollabEditor.CellRepo,
       dir: Application.get_env(:collab_editor, :cell_dir, "priv/cells"),
       max_resident: 128,
       key_for: &CollabEditor.Cells.Vault.key_for/1,
       migrator: CollabEditor.Cells.Schema},
      CollabEditorWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CollabEditor.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CollabEditorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
