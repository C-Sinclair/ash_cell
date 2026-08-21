defmodule Shroud.Sealing do
  @moduledoc """
  Sealing a payload to a user's published public key, server-side.

  This is how something with no session and no key of its own writes to a user who
  is offline: an Oban job, a webhook, another user's request. ECDH against the
  recipient's published P-256 key with a throwaway keypair, HKDF to an AES key,
  AES-256-GCM. The recipient opens it in their browser with the private key wrapped
  under their master key.

  Write-without-read, which is why an offline user is not a storage problem. It is
  only a *processing* problem — this module can put bytes in front of a user and
  still cannot read anything of theirs.

  ## Interop is the whole difficulty

  Every choice here exists to match what WebCrypto does, because the counterpart of
  this code is `assets/js/shroud/crypto.js` and a mismatch is a silent decryption
  failure rather than an error:

    * **Public keys are SPKI DER**, not the raw uncompressed point `:crypto` deals
      in. `subtle.exportKey("spki", …)` produces DER, so the fixed 26-byte P-256
      prefix is added and stripped here.
    * **The GCM tag is appended to the ciphertext.** WebCrypto returns one buffer;
      `:crypto` returns a `{ciphertext, tag}` tuple. Concatenating in that order is
      what makes `subtle.decrypt` accept it.
    * **HKDF is implemented rather than called.** `:crypto` has HMAC but no HKDF, so
      extract-then-expand is spelled out. The salt and `info` must match the JS byte
      for byte.

  Round-tripped against the browser implementation in `test/sealing_test.exs`.
  """

  # SPKI DER prefix for an id-ecPublicKey / prime256v1 subject public key. Fixed for
  # this curve, so a full ASN.1 encoder would be ceremony for a constant.
  @spki_p256_prefix <<0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02,
                      0x01, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03,
                      0x42, 0x00>>

  @seal_info "shroud.seal.v1"
  @tag_bytes 16

  @doc """
  Seals `plaintext` to a recipient's base64 SPKI public key.

  Returns the shape `Shroud.Profile.InboxItem` stores and the browser expects. The
  ephemeral private key is never returned or retained, so nothing left behind can
  re-derive this shared secret — including us, a moment later.
  """
  def seal_to(recipient_public_key_b64, plaintext) do
    with {:ok, recipient_point} <- decode_spki(recipient_public_key_b64) do
      {ephemeral_public, ephemeral_private} = :crypto.generate_key(:ecdh, :prime256v1)

      shared = :crypto.compute_key(:ecdh, recipient_point, ephemeral_private, :prime256v1)
      key = hkdf(shared, @seal_info)

      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, <<>>, true)

      {:ok,
       %{
         ciphertext: Base.encode64(ciphertext <> tag),
         iv: Base.encode64(iv),
         ephemeral_public_key: encode_spki(ephemeral_public)
       }}
    end
  end

  @doc """
  Opens a sealed payload with a raw private scalar.

  Present for tests and for symmetry. It is **not** used in the running app: the
  server never holds a user's identity private key, because that key is wrapped
  under a master key the server does not have. If a code path ever calls this with a
  real user's key, something has gone wrong upstream.
  """
  def open(private_key, %{} = sealed) do
    with {:ok, ephemeral_point} <- decode_spki(fetch(sealed, :ephemeral_public_key)),
         {:ok, blob} <- Base.decode64(fetch(sealed, :ciphertext)),
         {:ok, iv} <- Base.decode64(fetch(sealed, :iv)),
         true <- byte_size(blob) > @tag_bytes do
      shared = :crypto.compute_key(:ecdh, ephemeral_point, private_key, :prime256v1)
      key = hkdf(shared, @seal_info)

      split = byte_size(blob) - @tag_bytes
      <<ciphertext::binary-size(split), tag::binary>> = blob

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, <<>>, tag, false) do
        :error -> {:error, :decryption_failed}
        plaintext -> {:ok, plaintext}
      end
    else
      false -> {:error, :malformed}
      other -> other
    end
  end

  @doc """
  Delivers a sealed payload into a user's cell inbox.

  Binds explicitly. This is exactly the context the workspace notes warn about —
  a job has no request boundary to route on, and the binding is ambient and does not
  cross process boundaries, so relying on an inherited one would work in a test and
  fail in production.
  """
  def deliver(recipient_id, recipient_public_key, kind, plaintext, sender_handle \\ nil) do
    with {:ok, sealed} <- seal_to(recipient_public_key, plaintext) do
      Shroud.Profile.InboxItem.deliver(
        Map.merge(sealed, %{kind: kind, sender_handle: sender_handle}),
        tenant: recipient_id
      )
    end
  end

  @doc "Generates a P-256 pair in the shape the browser would produce. Tests only."
  def generate_keypair do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    {encode_spki(public), private}
  end

  defp encode_spki(<<4, _rest::binary-size(64)>> = point),
    do: Base.encode64(@spki_p256_prefix <> point)

  defp decode_spki(b64) when is_binary(b64) do
    with {:ok, der} <- Base.decode64(b64) do
      case der do
        <<@spki_p256_prefix, point::binary-size(65)>> -> {:ok, point}
        # Tolerate a raw uncompressed point too, so a caller that already has one
        # does not have to wrap it just to have it unwrapped again.
        <<4, _::binary-size(64)>> -> {:ok, der}
        _ -> {:error, :unsupported_public_key}
      end
    end
  end

  defp decode_spki(_), do: {:error, :missing_public_key}

  # HKDF-SHA256, extract then expand. One 32-byte output block is all we need, so
  # the expand loop collapses to a single HMAC.
  defp hkdf(ikm, info, salt \\ <<0::size(256)>>) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
