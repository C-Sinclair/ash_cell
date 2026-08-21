defmodule Shroud.FakeAuthenticator do
  @moduledoc """
  A WebAuthn authenticator in about a hundred lines, for testing the ceremonies.

  Everything a real authenticator produces, produced here: an ES256 keypair, CBOR
  attestation objects, correctly framed authenticator data, and real ECDSA
  assertions. That lets the whole `/auth` path be tested — challenge issuance, Wax
  verification, credential storage, the cell write, and login — without a browser or
  a human.

  What it deliberately cannot do is **PRF**. That value comes from the authenticator's
  own secret and there is no way to synthesise a meaningful one, which is exactly why
  `probes/prf/index.html` still needs a person. So these tests cover the
  authentication half of the passkey's job and not the key-derivation half.

  `attStmt` is empty and `fmt` is `"none"`, i.e. self-attestation with nothing to
  verify — the common real-world case for platform passkeys, and why `Shroud.Auth`
  trusts `:none`.
  """

  # UP (user present) | UV (user verified) | AT (attested credential data included)
  @flags_create 0x45
  # UP | UV, with no attested credential data on an assertion
  @flags_get 0x05
  @aaguid <<0::128>>

  defstruct [:credential_id, :public_key, :private_key, :rp_id, :origin, sign_count: 0]

  def new(opts \\ []) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

    %__MODULE__{
      credential_id: :crypto.strong_rand_bytes(32),
      public_key: public_key,
      private_key: private_key,
      rp_id: Keyword.get(opts, :rp_id, "localhost"),
      origin: Keyword.get(opts, :origin, "http://localhost:4000")
    }
  end

  @doc "What `navigator.credentials.create` would return, for a given challenge."
  def attest(%__MODULE__{} = auth, challenge_b64) do
    client_data = client_data("webauthn.create", challenge_b64, auth.origin)

    auth_data =
      rp_id_hash(auth) <>
        <<@flags_create, auth.sign_count::32>> <>
        @aaguid <>
        <<byte_size(auth.credential_id)::16>> <>
        auth.credential_id <>
        cose_key(auth)

    attestation =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    %{
      attestation_object: b64url(attestation),
      client_data_json: client_data,
      credential_id: b64url(auth.credential_id)
    }
  end

  @doc """
  What `navigator.credentials.get` would return.

  The signature is over `authData || SHA256(clientDataJSON)`, which is the detail
  worth spelling out: it binds the assertion to both the challenge and the origin, so
  a signature captured elsewhere cannot be replayed here.
  """
  def assert(%__MODULE__{} = auth, challenge_b64) do
    client_data = client_data("webauthn.get", challenge_b64, auth.origin)
    auth_data = rp_id_hash(auth) <> <<@flags_get, auth.sign_count::32>>

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data),
        [auth.private_key, :prime256v1]
      )

    %{
      credential_id: b64url(auth.credential_id),
      auth_data: b64url(auth_data),
      signature: b64url(signature),
      client_data_json: client_data
    }
  end

  defp client_data(type, challenge_b64, origin) do
    # Key order does not matter -- the server hashes the raw bytes it receives rather
    # than re-serialising, which is why clientDataJSON is passed around verbatim.
    Jason.encode!(%{
      "type" => type,
      "challenge" => challenge_b64,
      "origin" => origin,
      "crossOrigin" => false
    })
  end

  defp rp_id_hash(%{rp_id: rp_id}), do: :crypto.hash(:sha256, rp_id)

  # COSE_Key for ES256: kty=EC2(2), alg=ES256(-7), crv=P-256(1), plus the raw
  # coordinates from the uncompressed point.
  defp cose_key(%{public_key: <<4, x::binary-size(32), y::binary-size(32)>>}) do
    CBOR.encode(%{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => %CBOR.Tag{tag: :bytes, value: x},
      -3 => %CBOR.Tag{tag: :bytes, value: y}
    })
  end

  defp b64url(bytes), do: Base.url_encode64(bytes, padding: false)
end
