defmodule ShroudWeb.Plugs.CurrentUser do
  @moduledoc """
  Loads the signed-in user from the session, or nothing.

  Note what this does *not* do: unlock anything. Being authenticated and being able
  to read your own data are separate states in Shroud, and this plug only
  establishes the first. The master key is unlocked in the browser, and a session
  can legitimately be authenticated-but-locked — after a page reload, before the
  passkey prompt is answered. The UI has to render that state rather than assume it
  away.
  """
  import Plug.Conn

  alias Shroud.Global.User

  require Ash.Query

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :user_id) do
      nil ->
        assign(conn, :current_user, nil)

      user_id ->
        case User |> Ash.Query.filter(id == ^user_id) |> Ash.read_one() do
          {:ok, %User{shredded_at: nil} = user} ->
            assign(conn, :current_user, user)

          # Either gone or shredded. A shredded account keeps its row so other
          # users' edges resolve, but it must not be able to sign in.
          _ ->
            conn |> configure_session(drop: true) |> assign(:current_user, nil)
        end
    end
  end
end
