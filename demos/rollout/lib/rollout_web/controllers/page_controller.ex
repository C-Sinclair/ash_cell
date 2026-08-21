defmodule RolloutWeb.PageController do
  use RolloutWeb, :controller

  @doc """
  The visualiser.

  Served as one static page with no build step, because the app is scaffolded
  without an asset pipeline — and that turns out to be the honest choice here. Every
  dot on the canvas is a real `fetch` to `POST /v1/check`, and the buttons call the
  real promote and rollback routes, so what is being animated is the system rather
  than a mock of it.
  """
  def home(conn, _params) do
    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:home, channels: Rollout.Cells.channels())
  end
end
