defmodule RolloutWeb.PageTest do
  @moduledoc """
  That the visualiser is served as a whole document.

  It renders with layouts off, so the template carries its own `<head>` — and a
  missing doctype puts the page in quirks mode, which is exactly the kind of
  breakage nothing else here would notice.
  """
  use RolloutWeb.ConnCase, async: true

  test "serves a complete document", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "<!DOCTYPE html>"
    assert html =~ "</html>"
    assert html =~ "rollout"
  end

  test "renders a lane per channel", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    for channel <- Rollout.Cells.channels() do
      assert html =~ ~s(data-channel="#{channel}")
    end
  end

  test "drives the real API rather than a mock", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "/v1/check"
    assert html =~ ~s(data-action="upgrade")
    assert html =~ ~s(data-action="rollback")
  end
end
