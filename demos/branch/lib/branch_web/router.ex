defmodule BranchWeb.Router do
  use BranchWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BranchWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", BranchWeb do
    pipe_through :browser

    live "/", ConsoleLive, :index
    live "/:database", ConsoleLive, :database
    live "/:database/:branch", ConsoleLive, :branch
  end
end
