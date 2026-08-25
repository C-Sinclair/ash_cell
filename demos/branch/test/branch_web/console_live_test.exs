defmodule BranchWeb.ConsoleLiveTest do
  @moduledoc """
  The control plane end to end, through the page rather than the service.

  The load-bearing one is the refusal: the screen has to *say* why a promotion was
  refused, because a user shown only "conflict" cannot act on it, and the whole
  argument for fast-forward-or-refuse is that the refusal carries information.
  """
  use BranchWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Branch.Service

  setup do
    name = "ui#{System.system_time(:nanosecond)}#{System.unique_integer([:positive])}"
    {:ok, database: name}
  end

  test "a refused promotion explains itself on the page", %{conn: conn, database: db} do
    {:ok, _} = Service.provision(db)
    {:ok, _} = Service.query(db, "main", "CREATE TABLE t (id INTEGER PRIMARY KEY)")
    {:ok, _} = Service.create_branch(db, "main", "feature")
    {:ok, _} = Service.query(db, "feature", "INSERT INTO t (id) VALUES (1)")
    {:ok, _} = Service.query(db, "main", "INSERT INTO t (id) VALUES (2)")

    {:ok, view, _html} = live(conn, ~p"/#{db}/feature")

    html = view |> element("button", "Merge into parent") |> render_click()

    assert html =~ "Refused"
    assert html =~ "written to since this branch was cut"
    assert html =~ "no correct automatic merge"
  end

  test "a legal promotion fast-forwards from the page", %{conn: conn, database: db} do
    {:ok, _} = Service.provision(db)
    {:ok, _} = Service.query(db, "main", "CREATE TABLE t (id INTEGER PRIMARY KEY)")
    {:ok, _} = Service.create_branch(db, "main", "feature")
    {:ok, _} = Service.query(db, "feature", "INSERT INTO t (id) VALUES (1)")

    {:ok, view, _html} = live(conn, ~p"/#{db}/feature")

    assert view |> element("button", "Merge into parent") |> render_click() =~ "fast-forwarded"
  end
end
