defmodule ShroudWeb.PeopleLiveTest do
  @moduledoc """
  The directory as rendered, including the round trip that adding somebody requires:
  the server cannot seal a group key itself, so it has to ask the browser.
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
    {public_key, _} = Shroud.Sealing.generate_keypair()
    user = Ash.create!(Global.User, %{handle: handle, public_key: public_key}, action: :register)
    {Plug.Test.init_test_session(conn, %{user_id: user.id}), user}
  end

  defp other(handle) do
    {public_key, _} = Shroud.Sealing.generate_keypair()
    Ash.create!(Global.User, %{handle: handle, public_key: public_key}, action: :register)
  end

  defp with_audience(user) do
    {:ok, _} =
      Profiles.put_audience(user.id, %{
        slug: "friends",
        name: "Friends",
        wrapped_group_key: Base.encode64(:crypto.strong_rand_bytes(48)),
        iv: Base.encode64(:crypto.strong_rand_bytes(12))
      })

    user
  end

  test "lists other people so there is somebody to add", %{conn: conn} do
    {conn, user} = sign_in(conn, "me-#{System.unique_integer([:positive])}")
    with_audience(user)
    target = other("target-#{System.unique_integer([:positive])}")

    {:ok, _view, html} = live(conn, "/people")

    assert html =~ target.handle
    assert html =~ "Add"
  end

  test "searching narrows the list", %{conn: conn} do
    {conn, user} = sign_in(conn, "me-#{System.unique_integer([:positive])}")
    with_audience(user)
    wanted = other("needle-#{System.unique_integer([:positive])}")
    unwanted = other("haystack-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/people")

    html = view |> form("form[phx-change=search]", %{query: "needle"}) |> render_change()

    assert html =~ wanted.handle
    refute html =~ unwanted.handle
  end

  test "adding somebody asks the browser to seal, rather than doing it server-side",
       %{conn: conn} do
    {conn, user} = sign_in(conn, "me-#{System.unique_integer([:positive])}")
    with_audience(user)
    target = other("target-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/people")

    render_submit(element(view, "form[phx-submit=add_member]"), %{
      handle: target.handle,
      slug: "friends"
    })

    # The server pushes the recipient's *public* key out and waits. It never had the
    # group key in plaintext and cannot complete this on its own.
    assert_push_event(view, "seal_group_key_for", payload)
    assert payload.slug == "friends"
    assert payload.member_id == target.id
    assert payload.public_key == target.public_key

    # And nothing has been granted yet.
    assert Profiles.directory(user.id) |> Enum.all?(&(&1.in_my_audiences == []))
  end

  test "storing what the browser sealed completes the membership", %{conn: conn} do
    {conn, user} = sign_in(conn, "me-#{System.unique_integer([:positive])}")
    with_audience(user)
    target = other("target-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/people")

    html =
      render_hook(view, "member_sealed", %{
        "slug" => "friends",
        "member_id" => target.id,
        "sealed" => %{
          "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48)),
          "ephemeral_public_key" => Base.encode64(:crypto.strong_rand_bytes(91)),
          "iv" => Base.encode64(:crypto.strong_rand_bytes(12))
        }
      })

    assert html =~ "friends"
    assert [%{in_my_audiences: ["friends"]}] = Profiles.directory(user.id)
  end

  test "an unknown handle is reported rather than silently ignored", %{conn: conn} do
    {conn, user} = sign_in(conn, "me-#{System.unique_integer([:positive])}")
    with_audience(user)
    _target = other("target-#{System.unique_integer([:positive])}")

    {:ok, view, _html} = live(conn, "/people")

    html =
      render_submit(element(view, "form[phx-submit=add_member]"), %{
        handle: "nobody-at-all",
        slug: "friends"
      })

    assert html =~ "No user @nobody-at-all"
  end

  test "warns when there are no audiences to add anyone to", %{conn: conn} do
    {conn, _user} = sign_in(conn, "me-#{System.unique_integer([:positive])}")
    _target = other("target-#{System.unique_integer([:positive])}")

    {:ok, _view, html} = live(conn, "/people")

    # The exact dead end that made this unusable: an audience list of zero means the
    # Add control cannot be offered, so the page has to say why.
    assert html =~ "no audiences yet"
    assert html =~ "Create an audience"
  end

  test "explains itself when the viewer is the only account", %{conn: conn} do
    {conn, user} = sign_in(conn, "lonely-#{System.unique_integer([:positive])}")
    with_audience(user)

    {:ok, _view, html} = live(conn, "/people")

    assert html =~ "only account so far"
  end

  test "removing a member is offered and works", %{conn: conn} do
    {conn, user} = sign_in(conn, "me-#{System.unique_integer([:positive])}")
    with_audience(user)
    target = other("target-#{System.unique_integer([:positive])}")

    {:ok, _} =
      Profiles.add_member(user.id, "friends", target.id, %{
        "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48)),
        "ephemeral_public_key" => Base.encode64(:crypto.strong_rand_bytes(91)),
        "iv" => Base.encode64(:crypto.strong_rand_bytes(12))
      })

    {:ok, view, _html} = live(conn, "/people")

    view
    |> element("button[phx-click=remove_member]")
    |> render_click()

    assert [%{in_my_audiences: []}] = Profiles.directory(user.id)
  end
end
