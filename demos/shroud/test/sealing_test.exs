defmodule Shroud.SealingTest do
  @moduledoc """
  The sealed-box path, which is how anything writes to a user who is offline.
  """
  use ExUnit.Case, async: true

  alias Shroud.Sealing

  test "seals to a public key and opens with the matching private key" do
    {public, private} = Sealing.generate_keypair()

    {:ok, sealed} = Sealing.seal_to(public, "birthday: 1987-03-02")

    assert {:ok, "birthday: 1987-03-02"} = Sealing.open(private, sealed)
  end

  test "the ciphertext does not contain the plaintext" do
    {public, _private} = Sealing.generate_keypair()
    {:ok, sealed} = Sealing.seal_to(public, "CANARY_VALUE")

    refute String.contains?(Base.decode64!(sealed.ciphertext), "CANARY_VALUE")
    refute String.contains?(sealed.ciphertext, "CANARY")
  end

  test "a different private key cannot open it" do
    {public, _} = Sealing.generate_keypair()
    {_, other_private} = Sealing.generate_keypair()

    {:ok, sealed} = Sealing.seal_to(public, "secret")

    assert {:error, :decryption_failed} = Sealing.open(other_private, sealed)
  end

  test "each sealing uses a fresh ephemeral key, so two seals of the same plaintext differ" do
    {public, private} = Sealing.generate_keypair()

    {:ok, a} = Sealing.seal_to(public, "same")
    {:ok, b} = Sealing.seal_to(public, "same")

    refute a.ciphertext == b.ciphertext
    refute a.ephemeral_public_key == b.ephemeral_public_key

    # Both still open: the ephemeral public key travels with the payload.
    assert {:ok, "same"} = Sealing.open(private, a)
    assert {:ok, "same"} = Sealing.open(private, b)
  end

  test "a tampered ciphertext is rejected rather than returning garbage" do
    {public, private} = Sealing.generate_keypair()
    {:ok, sealed} = Sealing.seal_to(public, "authentic")

    raw = Base.decode64!(sealed.ciphertext)
    <<first, rest::binary>> = raw
    tampered = %{sealed | ciphertext: Base.encode64(<<Bitwise.bxor(first, 1)>> <> rest)}

    assert {:error, :decryption_failed} = Sealing.open(private, tampered)
  end

  test "public keys round-trip through the SPKI encoding WebCrypto expects" do
    {public, _private} = Sealing.generate_keypair()
    der = Base.decode64!(public)

    # 26-byte P-256 SPKI prefix + 65-byte uncompressed point.
    assert byte_size(der) == 91
    assert <<_prefix::binary-size(26), 4, _point::binary-size(64)>> = der
  end

  test "rejects a public key it does not understand instead of failing obscurely later" do
    assert {:error, :unsupported_public_key} = Sealing.seal_to(Base.encode64("nonsense"), "x")
    assert {:error, :missing_public_key} = Sealing.seal_to(nil, "x")
  end
end
