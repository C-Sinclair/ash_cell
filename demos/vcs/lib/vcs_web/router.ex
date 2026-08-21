defmodule VcsWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", VcsWeb do
    pipe_through(:api)

    # `owner/name` is two path segments, and the repository name is the tenant id.
    get("/repos/:owner/:name/refs", RepoController, :refs)
    post("/repos/:owner/:name/missing", RepoController, :missing)
    post("/repos/:owner/:name/objects", RepoController, :objects)
    post("/repos/:owner/:name/push", RepoController, :push)
    post("/repos/:owner/:name/fetch", RepoController, :fetch)

    # No client command calls these. They exist because a repository that is a database can
    # answer them, and Git's server cannot without a clone or a full object walk.
    get("/repos/:owner/:name/log", RepoController, :log)
    get("/repos/:owner/:name/history", RepoController, :history)
    get("/repos/:owner/:name/search", RepoController, :search)
    get("/repos/:owner/:name/tree", RepoController, :tree)
  end
end
