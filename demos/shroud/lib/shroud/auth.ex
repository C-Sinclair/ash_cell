defmodule Shroud.Auth do
  @moduledoc """
  Passkey registration and login, via Wax.

  ## This module knows nothing about encryption

  That separation is the single most important thing about it. A passkey does two
  unrelated jobs in Shroud:

    1. **It proves who you are.** An assertion Wax verifies against a stored COSE
       public key. That is this module's entire remit.
    2. **It hands your browser a key.** The `prf` extension returns deterministic
       bytes for a fixed salt. Those bytes never leave the browser, so they never
       reach this module, and nothing here can decrypt anything.

  Designs that try to make one mechanism serve both jobs go wrong — usually by
  trying to derive a key from a signature, which cannot work because ECDSA
  signatures are non-deterministic. Two jobs, two mechanisms, one gesture.

  If PRF output ever appears in a parameter here, that is a bug. The only
  key-shaped things this module accepts are *already-wrapped* blobs it cannot
  open (see `Shroud.Global.KeyWrap`).

  ## Challenges live in the session

  A challenge must be generated server-side, used once, and bound to the ceremony
  that consumed it. It is put in the Plug session rather than in ETS or the
  database because it is single-use, short-lived, and already scoped to exactly
  the right thing: this browser, this tab's request chain.
  """

  alias Shroud.Global.{Credential, User}

  require Ash.Query

  @doc """
  A registration challenge, plus the options the browser needs for
  `navigator.credentials.create`.

  `residentKey: "required"` is not decoration: a discoverable credential is what
  lets login start from "some passkey" rather than "this user's passkey", so the
  handle box can be skipped. `userVerification: "required"` is load-bearing for a
  different reason — PRF evaluation demands user verification, so a ceremony that
  settles for presence only would authenticate fine and then fail to produce a key.
  """
  def registration_challenge(handle) do
    user_id = :crypto.strong_rand_bytes(16)

    challenge =
      Wax.new_registration_challenge(
        origin: origin(),
        rp_id: rp_id(),
        user_verification: "required",
        trusted_attestation_types: [:none, :basic, :uncertain, :attca, :self]
      )

    opts = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rp: %{name: "Shroud", id: rp_id()},
      user: %{
        id: Base.url_encode64(user_id, padding: false),
        name: handle,
        displayName: handle
      },
      pubKeyCredParams: [
        %{type: "public-key", alg: -7},
        %{type: "public-key", alg: -257}
      ],
      authenticatorSelection: %{
        residentKey: "required",
        userVerification: "required"
      },
      extensions: %{prf: %{}}
    }

    {challenge, opts}
  end

  @doc """
  Verifies a registration and creates the user, their credential, and their key wraps.

  Everything lands in one Postgres transaction. A user whose `KeyWrap` rows failed
  to insert has an account they can log into and a master key nobody can recover —
  every Tier 1 write would succeed and be permanently unreadable. That is worse
  than a failed signup, so it must not be a reachable state.

  `wraps` are opaque to us. `public_key` is the user's ECDH P-256 public key, and
  publishing it is what makes writes to this user possible while they are offline.
  """
  def register(handle, attestation_object_b64, client_data_json, challenge, wraps, public_key) do
    with {:ok, attestation} <- decode64(attestation_object_b64),
         {:ok, {auth_data, _attestation_result}} <-
           Wax.register(attestation, client_data_json, challenge) do
      credential_id =
        auth_data.attested_credential_data.credential_id
        |> Base.url_encode64(padding: false)

      cose_key = :erlang.term_to_binary(auth_data.attested_credential_data.credential_public_key)

      Ash.transaction([User, Credential, Shroud.Global.KeyWrap], fn ->
        user = Ash.create!(User, %{handle: handle, public_key: public_key}, action: :register)

        Ash.create!(
          Credential,
          %{
            credential_id: credential_id,
            cose_key: cose_key,
            sign_count: auth_data.sign_count,
            user_id: user.id
          },
          action: :create
        )

        for wrap <- wraps do
          Ash.create!(
            Shroud.Global.KeyWrap,
            Map.put(atomise_wrap(wrap), :user_id, user.id),
            action: :create
          )
        end

        user
      end)
    end
  end

  @doc """
  An authentication challenge over every credential we know about.

  Passing every credential rather than one user's is what makes usernameless login
  work: the browser picks a discoverable credential and we find out who it belongs
  to afterwards, from the credential id it returns.
  """
  def authentication_challenge do
    credentials =
      Credential
      |> Ash.read!()
      |> Enum.map(fn c -> {c.credential_id, :erlang.binary_to_term(c.cose_key)} end)

    challenge =
      Wax.new_authentication_challenge(
        origin: origin(),
        rp_id: rp_id(),
        user_verification: "required",
        allow_credentials: credentials
      )

    opts = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rpId: rp_id(),
      userVerification: "required",
      allowCredentials: []
    }

    {challenge, opts}
  end

  @doc """
  Verifies an assertion and returns the user it belongs to, with their key wraps.

  The wraps go back to the browser because that is the only place they are useful:
  the client rebuilds the KEK from its PRF output or passphrase, unwraps the master
  key, and holds it for the session. We hand over sealed boxes and never learn what
  is in them.
  """
  def authenticate(credential_id, auth_data_b64, signature_b64, client_data_json, challenge) do
    with {:ok, auth_data} <- decode64(auth_data_b64),
         {:ok, signature} <- decode64(signature_b64),
         {:ok, verified} <-
           Wax.authenticate(
             credential_id,
             auth_data,
             signature,
             client_data_json,
             challenge
           ),
         {:ok, credential} <- fetch_credential(credential_id) do
      guard_sign_count(credential, verified)

      user =
        User
        |> Ash.Query.filter(id == ^credential.user_id)
        |> Ash.Query.load(:key_wraps)
        |> Ash.read_one!()

      if user && user.shredded_at do
        {:error, :account_shredded}
      else
        {:ok, user}
      end
    end
  end

  defp fetch_credential(credential_id) do
    Credential
    |> Ash.Query.filter(credential_id == ^credential_id)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> {:error, :unknown_credential}
      {:ok, credential} -> {:ok, credential}
      other -> other
    end
  end

  # A counter that goes backwards is the documented clone signal. Many platform
  # authenticators pin it at zero forever, so only a regression from a non-zero
  # stored value means anything -- treating a constant zero as suspicious would
  # reject most real passkeys.
  defp guard_sign_count(credential, auth_data) do
    cond do
      auth_data.sign_count == 0 and credential.sign_count == 0 ->
        :ok

      auth_data.sign_count > credential.sign_count ->
        Credential.bump_sign_count!(credential, auth_data.sign_count)

      true ->
        require Logger

        Logger.warning(
          "sign count regression for credential #{credential.credential_id}: " <>
            "stored #{credential.sign_count}, asserted #{auth_data.sign_count}"
        )
    end
  end

  defp atomise_wrap(wrap) do
    for {k, v} <- wrap, into: %{} do
      key = if is_atom(k), do: k, else: String.to_existing_atom(k)
      value = if key == :kind and is_binary(v), do: String.to_existing_atom(v), else: v
      {key, value}
    end
  end

  defp decode64(nil), do: {:error, :missing}

  defp decode64(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> Base.decode64(value)
    end
  end

  defp rp_id, do: Application.get_env(:shroud, :rp_id, "localhost")
  defp origin, do: Application.get_env(:shroud, :origin, "http://localhost:4000")
end
