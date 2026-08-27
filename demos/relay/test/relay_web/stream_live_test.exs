defmodule RelayWeb.StreamLiveTest do
  @moduledoc """
  That the page a reader reconnects to takes the same path as the page they
  arrived on first.

  Deliberately not a rendering test. What is worth asserting is that a client
  arriving cold and a client reconnecting produce the same text, because the claim
  is that an offset makes those two the same case.
  """
  use RelayWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Relay.Streams

  @moduletag :object_store
  @moduletag :capture_log

  defp new_id, do: "live_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"

  test "a reconnect renders the same stream as the first mount", %{conn: conn} do
    id = new_id()
    {:ok, ^id} = Streams.start("a prompt", id: id, tokens: 40, interval: 1, flush_every: 8)

    # Far enough that some of it has been flushed and truncated, so the mounts
    # below have to cross a tier boundary rather than reading one table.
    wait_for(fn ->
      match?({:ok, %{flushed_through: flushed}} when flushed > 0, Streams.tiers(id))
    end)

    Streams.kill(id)

    {:ok, view, _html} = live(conn, ~p"/g/#{id}")
    first = rendered_tokens(view)
    assert first != ""

    {:ok, other, _html} = live(conn, ~p"/g/#{id}")
    assert rendered_tokens(other) == first
  end

  defp rendered_tokens(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("div.font-mono")
    |> Floki.text()
    |> String.trim()
  end

  defp wait_for(fun, remaining \\ 200) do
    cond do
      fun.() -> :ok
      remaining == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_for(fun, remaining - 1)
    end
  end
end
