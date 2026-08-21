defmodule ShroudWeb.TimelineLiveTest do
  @moduledoc """
  The timeline as rendered. The assertions worth making are about what the *HTML*
  contains, because that is the boundary the security claim lives on: a private post
  must reach the browser as ciphertext, and its plaintext must appear nowhere in the
  markup the server produced.
  """
  use ShroudWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Shroud.{Global, Profiles}

  require Ash.Query

  setup do
    on_exit(fn ->
      for user <- Ash.read!(Global.User) do
        AshCell.close(user.id)
        Shroud.Shred.collect_file(user.id)
      end
    end)

    :ok
  end

  defp sign_in(conn, handle) do
    {public_key, _priv} = Shroud.Sealing.generate_keypair()

    user =
      Ash.create!(Global.User, %{handle: handle, public_key: public_key}, action: :register)

    {Plug.Test.init_test_session(conn, %{user_id: user.id}), user}
  end

  test "renders a public post as readable text", %{conn: conn} do
    {conn, user} = sign_in(conn, "pub-#{System.unique_integer([:positive])}")

    {:ok, _} =
      Profiles.publish_post(user.id, %{visibility: "public", body: "readable by design"})

    {:ok, _view, html} = live(conn, "/home")

    assert html =~ "readable by design"
    assert html =~ "Public"
  end

  test "a private post reaches the browser as ciphertext, with no plaintext in the HTML",
       %{conn: conn} do
    {conn, user} = sign_in(conn, "priv-#{System.unique_integer([:positive])}")

    # Encrypted the way the browser would, so the server never sees the canary.
    content_key = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(12)
    canary = "CANARY_POST_BODY_9f2a"

    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, content_key, iv, canary, <<>>, true)

    {:ok, _} =
      Profiles.publish_post(user.id, %{
        visibility: "friends",
        ciphertext: Base.encode64(ct <> tag),
        iv: Base.encode64(iv),
        content_key_id: "ck",
        wrapped_content_key: Base.encode64(:crypto.strong_rand_bytes(48)),
        wrap_iv: Base.encode64(:crypto.strong_rand_bytes(12)),
        own_wrapped_content_key: Base.encode64(:crypto.strong_rand_bytes(48)),
        own_wrap_iv: Base.encode64(:crypto.strong_rand_bytes(12))
      })

    {:ok, _view, html} = live(conn, "/home")

    refute html =~ canary
    # The ciphertext *is* there, in the attribute the hook reads.
    assert html =~ "data-post"
    assert html =~ "encrypted"
  end

  test "the composer offers public plus each audience", %{conn: conn} do
    {conn, user} = sign_in(conn, "comp-#{System.unique_integer([:positive])}")

    {:ok, _} =
      Profiles.put_audience(user.id, %{
        slug: "friends",
        name: "Friends",
        wrapped_group_key: Base.encode64(:crypto.strong_rand_bytes(48)),
        iv: Base.encode64(:crypto.strong_rand_bytes(12))
      })

    {:ok, _view, html} = live(conn, "/home")

    assert html =~ "server can read"
    assert html =~ "Friends"
  end

  test "publishing a public post from the composer round-trips", %{conn: conn} do
    {conn, _user} = sign_in(conn, "rt-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/home")

    html =
      view
      |> render_hook("publish", %{"visibility" => "public", "body" => "hello from the test"})

    assert html =~ "hello from the test"
  end

  test "an empty timeline explains itself rather than showing a blank column", %{conn: conn} do
    {conn, _user} = sign_in(conn, "empty-#{System.unique_integer([:positive])}")

    {:ok, _view, html} = live(conn, "/home")

    assert html =~ "Nothing here yet"
  end

  test "the aside reports how many cells the server opened", %{conn: conn} do
    {conn, user} = sign_in(conn, "count-#{System.unique_integer([:positive])}")
    {:ok, _} = Profiles.publish_post(user.id, %{visibility: "public", body: "one"})

    {:ok, _view, html} = live(conn, "/home")

    assert html =~ "Cells opened"
    assert html =~ "Posts it could read"
  end
end
