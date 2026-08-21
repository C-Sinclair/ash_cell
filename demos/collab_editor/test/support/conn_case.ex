defmodule CollabEditorWeb.ConnCase do
  @moduledoc """
  Test case for anything that talks HTTP or LiveView.

  There is no Ecto sandbox here, and there cannot be: a cell is a file with its
  own connection, so a test's isolation comes from using its own document. Tests
  create the documents they need and the cell directory is thrown away between
  runs (`config/test.exs` points it at `tmp/`).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint CollabEditorWeb.Endpoint

      use CollabEditorWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
    end
  end

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
