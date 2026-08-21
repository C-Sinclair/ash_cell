defmodule ShroudWeb.AuthFlowTest do
  @moduledoc """
  The two ceremonies end to end, against a synthetic authenticator.

  Covers everything except PRF, which cannot be synthesised — see
  `Shroud.FakeAuthenticator`. The multi-account feed path this exercises is the one a
  human would click through: two accounts register, one shares with the other, and
  the second sees the first in their feed.
  """
  use ShroudWeb.ConnCase, async: false

  alias Shroud.FakeAuthenticator, as: FA
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

  describe "registration" do
    test "creates the user, credential, key wraps, and the identity blob in their cell", %{
      conn: conn
    } do
      auth = FA.new()
      handle = "ada-#{System.unique_integer([:positive])}"

      {conn, user} = register(conn, auth, handle)

      assert user["handle"] == handle

      stored = Global.User |> Ash.Query.filter(handle == ^handle) |> Ash.read_one!()
      assert stored.public_key

      creds = Global.Credential |> Ash.Query.filter(user_id == ^stored.id) |> Ash.read!()
      assert length(creds) == 1

      wraps = Global.KeyWrap |> Ash.Query.filter(user_id == ^stored.id) |> Ash.read!()
      assert Enum.map(wraps, & &1.kind) == [:passphrase]

      # The identity private key went into the user's own cell, not into Postgres
      # beside their key wraps.
      assert {:ok, field} = Shroud.Profile.Field.by_key("__identity", tenant: stored.id)
      assert field.content_key_id == "mk"

      # And the session is signed in.
      assert get_session(conn, :user_id) == stored.id
    end

    test "rejects a duplicate handle before touching the authenticator", %{conn: conn} do
      auth = FA.new()
      handle = "grace-#{System.unique_integer([:positive])}"
      {_conn, _user} = register(build_conn(), auth, handle)

      conn = post_json(conn, "/auth/registration_options", %{handle: handle})

      assert json_response(conn, 422)["error"] =~ "taken"
    end

    test "rejects a blank handle", %{conn: conn} do
      conn = post_json(conn, "/auth/registration_options", %{handle: "   "})
      assert json_response(conn, 422)["error"] =~ "blank"
    end

    test "a challenge is single-use", %{conn: conn} do
      auth = FA.new()
      handle = "edsger-#{System.unique_integer([:positive])}"

      conn = post_json(conn, "/auth/registration_options", %{handle: handle})
      %{"options" => options} = json_response(conn, 200)
      attested = FA.attest(auth, options["challenge"])

      body = register_body(handle, attested)

      conn = conn |> recycle_session() |> post_json("/auth/register", body)
      assert json_response(conn, 200)

      # Replaying the same attestation must fail: the challenge was consumed. Without
      # this, a captured registration could be submitted twice.
      conn = conn |> recycle_session() |> post_json("/auth/register", body)
      assert json_response(conn, 400)["error"] =~ "expired"
    end
  end

  describe "login" do
    test "returns the key wraps and the identity blob, and nothing that can open them", %{
      conn: conn
    } do
      auth = FA.new()
      handle = "barbara-#{System.unique_integer([:positive])}"
      {_conn, _user} = register(build_conn(), auth, handle)

      conn = post_json(conn, "/auth/authentication_options", %{})
      %{"options" => options} = json_response(conn, 200)

      asserted = FA.assert(auth, options["challenge"])
      conn = conn |> recycle_session() |> post_json("/auth/authenticate", asserted)

      body = json_response(conn, 200)

      assert body["user"]["handle"] == handle
      assert [%{"kind" => "passphrase"}] = body["wraps"]
      assert body["wrapped_identity"]["ciphertext"]

      # What the server hands back is opaque to it. Nothing in the payload is a key.
      refute Map.has_key?(hd(body["wraps"]), "key")
      assert hd(body["wraps"])["kdf_iterations"] == 600_000
    end

    test "a shredded account cannot sign in", %{conn: conn} do
      auth = FA.new()
      handle = "gone-#{System.unique_integer([:positive])}"
      {_conn, user} = register(build_conn(), auth, handle)

      {:ok, _} = Shroud.Shred.cryptoshred(user["id"])

      conn = post_json(conn, "/auth/authentication_options", %{})
      %{"options" => options} = json_response(conn, 200)
      asserted = FA.assert(auth, options["challenge"])

      conn = conn |> recycle_session() |> post_json("/auth/authenticate", asserted)
      assert json_response(conn, 401)["error"] =~ "deleted"
    end

    test "an unknown credential is refused", %{conn: conn} do
      auth = FA.new()
      {_conn, _user} = register(build_conn(), auth, "known-#{System.unique_integer([:positive])}")

      stranger = FA.new()

      conn = post_json(conn, "/auth/authentication_options", %{})
      %{"options" => options} = json_response(conn, 200)
      asserted = FA.assert(stranger, options["challenge"])

      conn = conn |> recycle_session() |> post_json("/auth/authenticate", asserted)
      assert json_response(conn, 401)
    end

    test "an assertion for the wrong origin is refused", %{conn: conn} do
      auth = FA.new()
      handle = "origin-#{System.unique_integer([:positive])}"
      {_conn, _user} = register(build_conn(), auth, handle)

      evil = %{auth | origin: "http://evil.example"}

      conn = post_json(conn, "/auth/authentication_options", %{})
      %{"options" => options} = json_response(conn, 200)
      asserted = FA.assert(evil, options["challenge"])

      conn = conn |> recycle_session() |> post_json("/auth/authenticate", asserted)
      assert json_response(conn, 401)
    end
  end

  describe "two accounts, one feed" do
    test "a second account sees the first once shared with, without the first present", %{
      conn: _conn
    } do
      alice_auth = FA.new()
      bob_auth = FA.new()
      alice_handle = "alice-#{System.unique_integer([:positive])}"
      bob_handle = "bob-#{System.unique_integer([:positive])}"

      {_c1, alice} = register(build_conn(), alice_auth, alice_handle)
      {_c2, bob} = register(build_conn(), bob_auth, bob_handle)

      # Alice writes a field shared with "friends" and adds Bob to that audience.
      # Both steps are things the browser does with keys; here they are stand-ins,
      # because what is under test is the plumbing, not the crypto.
      {:ok, _} = put_shared_field(alice["id"], "display_name", "friends")

      {:ok, _} =
        Profiles.add_member(alice["id"], "friends", bob["id"], %{
          "ciphertext" => Base.encode64(:crypto.strong_rand_bytes(48)),
          "ephemeral_public_key" => Base.encode64(:crypto.strong_rand_bytes(91)),
          "iv" => Base.encode64(:crypto.strong_rand_bytes(12))
        })

      # Alice is entirely absent: cell closed, no binding, no session.
      AshCell.close(alice["id"])
      AshCell.unbind()

      assert [entry] = Profiles.feed(bob["id"])
      assert entry.handle == alice_handle
      assert [%{key: "display_name"}] = entry.fields
      assert [%{audience_slug: "friends"}] = entry.grants
      assert [%{audience_slug: "friends"}] = entry.memberships

      # And it is not mutual: Bob has shared nothing, so Alice's feed is empty.
      assert Profiles.feed(alice["id"]) == []
    end
  end

  # ------------------------------------------------------------------ helpers

  defp register(conn, auth, handle) do
    conn = post_json(conn, "/auth/registration_options", %{handle: handle})
    %{"options" => options} = json_response(conn, 200)

    attested = FA.attest(auth, options["challenge"])

    conn =
      conn
      |> recycle_session()
      |> post_json("/auth/register", register_body(handle, attested))

    %{"user" => user} = json_response(conn, 200)
    {conn, user}
  end

  defp register_body(handle, attested) do
    %{
      handle: handle,
      attestation_object: attested.attestation_object,
      client_data_json: attested.client_data_json,
      public_key: elem(Shroud.Sealing.generate_keypair(), 0),
      wraps: [
        %{
          kind: "passphrase",
          wrapped_key: Base.encode64(:crypto.strong_rand_bytes(48)),
          iv: Base.encode64(:crypto.strong_rand_bytes(12)),
          kdf_salt: Base.encode64(:crypto.strong_rand_bytes(16)),
          kdf_iterations: 600_000
        }
      ],
      wrapped_identity: %{
        ciphertext: Base.encode64(:crypto.strong_rand_bytes(120)),
        iv: Base.encode64(:crypto.strong_rand_bytes(12))
      }
    }
  end

  defp put_shared_field(owner_id, key, audience_slug) do
    Profiles.put_field(
      owner_id,
      %{
        key: key,
        ciphertext: Base.encode64(:crypto.strong_rand_bytes(64)),
        iv: Base.encode64(:crypto.strong_rand_bytes(12)),
        content_key_id: "ck-test"
      },
      [
        %{
          field_key: key,
          audience_slug: audience_slug,
          wrapped_content_key: Base.encode64(:crypto.strong_rand_bytes(48)),
          iv: Base.encode64(:crypto.strong_rand_bytes(12))
        }
      ]
    )
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-csrf-token", Plug.CSRFProtection.get_csrf_token())
    |> post(path, Jason.encode!(body))
  end

  # Carries the session cookie forward the way a browser would, so the challenge
  # token issued by one request is visible to the next.
  defp recycle_session(conn), do: Phoenix.ConnTest.recycle(conn)
end
