defmodule CollabEditorWeb.Router do
  use CollabEditorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CollabEditorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", CollabEditorWeb do
    pipe_through :browser

    live "/", IndexLive, :index
    live "/docs/:id", EditorLive, :show
  end
end
