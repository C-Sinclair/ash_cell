defmodule Vcs.Test.RepoCase do
  @moduledoc """
  A test case with one freshly named repository cell.

  Names are unique per test so cells never collide, and each is closed and deleted afterwards —
  a leaked cell would hold a connection to a file the next run expects to be absent.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Vcs.Test.Builder
      alias Vcs.Test.Builder
    end
  end

  setup context do
    name =
      "test/#{context.test |> to_string() |> String.replace(~r/[^a-zA-Z0-9]+/, "-")}-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      AshCell.delete(name)
    end)

    {:ok, repo_name: name}
  end
end
