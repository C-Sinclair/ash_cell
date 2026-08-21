defmodule Shroud.Global.KeyWrap do
  @moduledoc """
  A master key, encrypted under something that can unlock it. One row per unlock path.

  The master key (MK) is 32 random bytes generated in the browser at signup. It is
  never transmitted. What is transmitted, and stored here, is MK sealed under a
  key-encryption key that only the client can reconstruct:

    * `:prf`        — KEK from HKDF over the passkey's WebAuthn PRF output
    * `:passphrase` — KEK from PBKDF2-SHA512 over a recovery passphrase
    * `:device`     — KEK from an additional passkey's PRF output

  Each row is therefore useless on its own. The server holding all of them still
  cannot recover MK, because it has neither the authenticator nor the passphrase.

  ## This table is the shred

  `Shroud.Shred.cryptoshred/1` deletes every row for a user in one transaction.
  After that MK is unrecoverable by anyone, including the user, and every Tier 1
  ciphertext in their cell is permanently noise — without touching the cell file,
  so the Tier 0 rows other users depend on keep resolving.

  What this does *not* reach: content keys the user already wrapped to somebody
  else's public key. Those never routed through MK, so shredding cannot revoke
  them. "What you shared with Alice, Alice keeps" is a property of the design, not
  an oversight, and the deletion UI says so in plain words.
  """
  use Ash.Resource,
    domain: Shroud.Global,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("key_wraps")
    repo(Shroud.Repo)

    references do
      reference(:user, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:kind, :atom,
      constraints: [one_of: [:prf, :passphrase, :device]],
      allow_nil?: false,
      public?: true
    )

    # MK sealed with AES-256-GCM under the KEK this row's `kind` describes.
    attribute(:wrapped_key, :string, allow_nil?: false, public?: true)
    attribute(:iv, :string, allow_nil?: false, public?: true)

    # Public KDF inputs. Safe to store: they are salts, not secrets, and the
    # client needs them back to rebuild the same KEK on another device.
    attribute(:kdf_salt, :string, public?: true)
    attribute(:kdf_iterations, :integer, public?: true)
    attribute(:credential_id, :string, public?: true)
    attribute(:label, :string, public?: true)

    timestamps()
  end

  relationships do
    belongs_to :user, Shroud.Global.User, allow_nil?: false
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :kind,
        :wrapped_key,
        :iv,
        :kdf_salt,
        :kdf_iterations,
        :credential_id,
        :label,
        :user_id
      ])

      primary?(true)
    end
  end

  code_interface do
    define(:create)
  end
end
