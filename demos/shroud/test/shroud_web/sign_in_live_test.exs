defmodule ShroudWeb.SignInLiveTest do
  use ShroudWeb.ConnCase

  import Phoenix.LiveViewTest

  test "offers both ceremonies", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Sign in"
    assert html =~ "Create account"
  end

  test "is explicit that public posts are not encrypted", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    # The tier split has to be on the landing page, not buried in docs. Somebody
    # deciding whether to trust this needs to know what "public" costs before they
    # sign up, not after they post.
    assert html =~ "Public posts are not"
    assert html =~ "stored in the clear"
  end

  test "registration names the irreversible risk before you take it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html = view |> element("button", "Create account") |> render_click()

    assert html =~ "Handle"
    # The one thing a user cannot recover from, said before they commit rather than
    # after they lose access.
    assert html =~ "gone for good"
    assert html =~ "the design working, not failing"
  end

  test "says up front that unlocking is a second step", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    # Two passkey prompts is surprising enough that not warning about it reads as a bug.
    assert html =~ "twice"
  end

  test "does not enumerate users to an unauthenticated visitor", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    refute html =~ "@ada"
    refute html =~ "@grace"
  end
end
