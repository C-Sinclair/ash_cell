defmodule AshCell.Test.Notifier do
  @moduledoc """
  Sends each notification to the pid under `:ash_cell_notify` in the notifying
  process, so a test can see which notifications were delivered and when.
  """
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{} = notification) do
    case Process.get(:ash_cell_notify) do
      nil -> :ok
      pid -> send(pid, {:notified, notification.action.name, notification.data.name})
    end

    :ok
  end
end
