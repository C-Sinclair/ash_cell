defmodule RelayWeb.Router do
  use RelayWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RelayWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RelayWeb do
    pipe_through :browser

    live "/", StreamLive, :index
    live "/g/:id", StreamLive, :show
  end
end
