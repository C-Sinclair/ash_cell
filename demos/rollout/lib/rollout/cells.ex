defmodule Rollout.Cells do
  @moduledoc """
  Where the fleet's channels are, and what they are called.

  There is no global registry in this demo, unlike `console`. A channel *is* its
  cell, its name is its key, and the demo deliberately does not stand up Postgres
  to record a mapping from a name to itself. The cross-store story is `console`'s
  to prove; this demo's subject is the pointer.
  """

  @channels ~w[myapp/prod myapp/beta myapp/canary]

  def channels, do: @channels

  def config do
    [
      dir: Application.get_env(:ash_cell, :dir, "priv/cells"),
      migrations_path: Rollout.Schema.migrations_path(),
      max_resident: 64
    ]
  end
end
