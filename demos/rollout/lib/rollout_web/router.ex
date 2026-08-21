defmodule RolloutWeb.Router do
  use RolloutWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RolloutWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RolloutWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/v1", RolloutWeb do
    pipe_through :api

    # The device path. No channel in the URL, because a client sends its channel
    # alongside everything else it is -- and because this is the one route that has
    # to stay trivially cacheable and writes nothing.
    post "/check", UpdatesController, :check

    get "/channels", ControlController, :index

    # The action leads and the channel trails, because a channel name has a slash
    # in it (`myapp/prod`) -- which is what a real fleet looks like -- and a glob
    # segment has to be last. It also curls better than the alternative.
    post "/releases/*channel", ControlController, :cut
    post "/promote/*channel", ControlController, :promote
    post "/upgrade/*channel", ControlController, :upgrade
    post "/ramp/*channel", ControlController, :ramp
    post "/rollback/*channel", ControlController, :rollback
    get "/collectable/*channel", ControlController, :collectable
    get "/channels/*channel", ControlController, :show
  end
end
