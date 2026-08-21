defmodule Shroud.Profile.Field do
  @moduledoc """
  One profile field — display name, birthday, bio, avatar pointer.

  This resource is where the two tiers meet in a single row, and the split is the
  point:

    * Tier 0, server-visible: `key`, `updated_at`. The server needs `key` to know
      which slot a row fills without decrypting it, and `updated_at` to keep
      `Shroud.Global.FeedEdge` current.
    * Tier 1, opaque: `ciphertext`, `iv`. AES-256-GCM under this field's content
      key. The server has no path to that key and cannot read these bytes.

  So the server can tell you that Alice has a birthday on file and when she last
  changed it. It cannot tell you the birthday. That is the honest boundary, and
  writing `key` in plaintext is a deliberate choice rather than an oversight —
  hiding it would mean the server could not render a profile skeleton or maintain
  a feed without a client online.

  Each field gets its own content key, which is what makes per-field audience
  selection fall out for free: sharing a birthday with Family and a display name
  with Public is two independent wraps, not a re-encryption.
  """
  use Ash.Resource,
    domain: Shroud.Profile,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("profile_fields")
    repo(Shroud.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:ciphertext, :string, allow_nil?: false, public?: true)
    attribute(:iv, :string, allow_nil?: false, public?: true)

    # Which content key this row was sealed under. Lets a rotation land without
    # having to guess which rows are already re-encrypted.
    attribute(:content_key_id, :string, allow_nil?: false, public?: true)

    attribute(:updated_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )
  end

  identities do
    identity(:unique_key, [:key])
  end

  actions do
    defaults([:read, :destroy])

    create :put do
      accept([:key, :ciphertext, :iv, :content_key_id])
      primary?(true)
      upsert?(true)
      upsert_identity(:unique_key)
      upsert_fields([:ciphertext, :iv, :content_key_id, :updated_at])
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    read :by_key do
      argument(:key, :string, allow_nil?: false)
      get?(true)
      filter(expr(key == ^arg(:key)))
    end
  end

  code_interface do
    define(:put)
    define(:by_key, args: [:key])
    define(:read, action: :read)
  end
end
