defmodule ShroudWeb.Router do
  use ShroudWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ShroudWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ShroudWeb.Plugs.CurrentUser
  end

  # The ceremony endpoints accept JSON but still need the session, for the
  # challenge token, and CSRF protection, because a forged registration would let
  # an attacker bind their own passkey to a handle of their choosing.
  pipeline :ceremony do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
  end

  scope "/auth", ShroudWeb do
    pipe_through :ceremony

    post "/registration_options", AuthController, :registration_options
    post "/register", AuthController, :register
    post "/authentication_options", AuthController, :authentication_options
    post "/authenticate", AuthController, :authenticate
    post "/logout", AuthController, :logout
  end

  scope "/", ShroudWeb do
    pipe_through :browser

    live_session :public, on_mount: [{ShroudWeb.LiveAuth, :mount_current_user}] do
      live "/", SignInLive, :index
    end

    live_session :authenticated, on_mount: [{ShroudWeb.LiveAuth, :require_user}] do
      live "/home", TimelineLive, :index
      live "/profile", ProfileLive, :index
      live "/people", PeopleLive, :index
      live "/u/:handle", ProfileViewLive, :show
      live "/settings", SettingsLive, :index
    end
  end
end
