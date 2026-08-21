defmodule ShroudWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks for LiveView session handling.

  `:locked?` starts true on every mount and is only cleared by the client telling
  us it has a master key. The server cannot verify that claim and does not try to:
  a client that lies about being unlocked gets ciphertext it cannot read, which is
  a broken UI rather than a security failure. The flag drives rendering, never
  authorisation.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias Shroud.Global.User

  require Ash.Query

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, assign_user(socket, session)}
  end

  def on_mount(:require_user, _params, session, socket) do
    socket = assign_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  defp assign_user(socket, session) do
    user =
      case session["user_id"] do
        nil ->
          nil

        id ->
          case User |> Ash.Query.filter(id == ^id) |> Ash.read_one() do
            {:ok, %User{shredded_at: nil} = user} -> user
            _ -> nil
          end
      end

    socket
    |> assign(:current_user, user)
    |> assign_new(:locked?, fn -> true end)
  end
end
