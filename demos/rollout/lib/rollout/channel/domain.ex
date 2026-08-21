defmodule Rollout.Channel do
  @moduledoc """
  One release channel's contents: `myapp/prod`, `myapp/beta`, `myapp/canary`.

  Every resource here lives in that channel's cell, which is one encrypted SQLite
  file with one writer. The cell is not a tenant and not a record — it is a
  *coordination scope*: the smallest thing that has to agree with itself about what
  is being served right now.
  """
  use Ash.Domain

  resources do
    resource(Rollout.Channel.Release)
    resource(Rollout.Channel.Artifact)
    resource(Rollout.Channel.Pointer)
    resource(Rollout.Channel.Promotion)
  end
end
