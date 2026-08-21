defmodule CollabEditorWeb.Presence do
  @moduledoc """
  Who is in a document right now.

  Deliberately *not* in the cell. Presence is ephemeral cluster state with a
  lifetime measured in seconds; writing it to a document's SQLite file would put
  a write on the cell's single connection for every cursor move, competing with
  the edits that actually matter. The cell is for what must survive a restart.
  """
  use Phoenix.Presence,
    otp_app: :collab_editor,
    pubsub_server: CollabEditor.PubSub
end
