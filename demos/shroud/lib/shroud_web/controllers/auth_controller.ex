defmodule ShroudWeb.AuthController do
  @moduledoc """
  JSON endpoints for the two WebAuthn ceremonies.

  Deliberately a controller rather than a LiveView. A ceremony is a short
  request/response exchange driven by `navigator.credentials`, with no incremental
  UI to push — routing it over a websocket would add a channel to reason about
  without removing anything.

  ## What crosses this boundary

  Inbound: attestations, assertions, and **sealed blobs the server cannot open**.
  Outbound: challenges, and those same sealed blobs handed back.

  What must never cross it: PRF output, a passphrase, a master key, or a content
  key. Every payload named `wrap`, `wrapped_*`, or `ciphertext` here is opaque by
  construction — that is not a convention to be polite about, it is the security
  property.
  """
  use ShroudWeb, :controller

  alias Shroud.Auth
  alias Shroud.Auth.ChallengeStore
  alias Shroud.Global.User
  alias Shroud.Profile

  require Ash.Query

  @identity_field "__identity"

  def registration_options(conn, %{"handle" => handle}) do
    handle = String.trim(handle)

    cond do
      handle == "" ->
        error(conn, 422, "handle cannot be blank")

      handle_taken?(handle) ->
        error(conn, 422, "that handle is taken")

      true ->
        {challenge, options} = Auth.registration_challenge(handle)

        conn
        |> put_session(:registration_token, ChallengeStore.put(challenge))
        |> json(%{options: options})
    end
  end

  def register(conn, params) do
    with {:ok, challenge} <- ChallengeStore.take(get_session(conn, :registration_token)),
         {:ok, user} <-
           Auth.register(
             params["handle"],
             params["attestation_object"],
             params["client_data_json"],
             challenge,
             params["wraps"] || [],
             params["public_key"]
           ) do
      store_wrapped_identity(user.id, params["wrapped_identity"])
      store_default_audience(user.id, params["audience"])

      conn
      |> delete_session(:registration_token)
      |> put_session(:user_id, user.id)
      |> json(%{user: %{id: user.id, handle: user.handle}})
    else
      :error -> error(conn, 400, "registration challenge expired; start again")
      {:error, reason} -> error(conn, 422, describe(reason))
    end
  end

  def authentication_options(conn, _params) do
    {challenge, options} = Auth.authentication_challenge()

    conn
    |> put_session(:authentication_token, ChallengeStore.put(challenge))
    |> json(%{options: options})
  end

  def authenticate(conn, params) do
    with {:ok, challenge} <- ChallengeStore.take(get_session(conn, :authentication_token)),
         {:ok, user} <-
           Auth.authenticate(
             params["credential_id"],
             params["auth_data"],
             params["signature"],
             params["client_data_json"],
             challenge
           ) do
      conn
      |> delete_session(:authentication_token)
      |> put_session(:user_id, user.id)
      |> json(%{
        user: %{id: user.id, handle: user.handle},
        wraps: Enum.map(user.key_wraps, &wrap_json/1),
        wrapped_identity: read_wrapped_identity(user.id)
      })
    else
      :error -> error(conn, 400, "login challenge expired; try again")
      {:error, reason} -> error(conn, 401, describe(reason))
    end
  end

  def logout(conn, _params) do
    conn |> configure_session(drop: true) |> json(%{ok: true})
  end

  # The identity private key is Tier 1 data like any other, so it belongs in the
  # user's cell rather than beside their key wraps in Postgres. Stored under a
  # reserved key and wrapped directly under MK rather than a content key, which is
  # what `content_key_id: "mk"` records -- there is no audience that could ever be
  # given this, so a content key would be indirection with no purpose.
  defp store_wrapped_identity(_user_id, nil), do: :ok

  defp store_wrapped_identity(user_id, %{"ciphertext" => ciphertext, "iv" => iv}) do
    Profile.Field.put!(
      %{key: @identity_field, ciphertext: ciphertext, iv: iv, content_key_id: "mk"},
      tenant: user_id
    )

    :ok
  end

  # A default audience, wrapped by the browser under a master key we never see. Created
  # at registration because the alternative is a new account with no audiences, which
  # means nowhere to add anybody and nothing to do but post publicly.
  defp store_default_audience(_user_id, nil), do: :ok

  defp store_default_audience(user_id, audience) do
    Profile.Audience.put!(
      %{
        slug: audience["slug"],
        name: audience["name"],
        wrapped_group_key: audience["wrapped_group_key"],
        iv: audience["iv"]
      },
      tenant: user_id
    )

    :ok
  end

  defp read_wrapped_identity(user_id) do
    case Profile.Field.by_key(@identity_field, tenant: user_id) do
      {:ok, %{ciphertext: ciphertext, iv: iv}} -> %{ciphertext: ciphertext, iv: iv}
      _ -> nil
    end
  end

  defp wrap_json(wrap) do
    %{
      kind: wrap.kind,
      wrapped_key: wrap.wrapped_key,
      iv: wrap.iv,
      kdf_salt: wrap.kdf_salt,
      kdf_iterations: wrap.kdf_iterations,
      credential_id: wrap.credential_id
    }
  end

  defp handle_taken?(handle) do
    User |> Ash.Query.filter(handle == ^handle) |> Ash.read_one!() != nil
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  defp describe(:account_shredded),
    do: "this account has been deleted and its keys destroyed"

  defp describe(:unknown_credential), do: "unrecognised passkey"
  defp describe(%{message: message}), do: message
  defp describe(other), do: inspect(other)
end
