defmodule Shroud.Profile.InboxItem do
  @moduledoc """
  A payload sealed to this user's public key by somebody else, waiting to be read.

  This is the answer to "how does data get stored for a user who is offline and
  whose key is therefore nowhere on the server". Anyone — another user, or a
  background job with no session at all — can do ECDH against the user's published
  public key, derive a one-time AES key, and write the result here. The write needs
  no secret of the recipient's. The read needs the recipient's master key, and so
  happens in their browser at next login.

  Write-without-read, which is the standard shape and the reason an offline user is
  not actually a problem for storage — only for *processing*.

  Note that this resource is written from a context that has no request boundary
  to route on, so callers must bind explicitly via `AshCell.with_tenant/2` or pass
  `tenant:`. An inherited binding is never safe here.
  """
  use Ash.Resource,
    domain: Shroud.Profile,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("inbox_items")
    repo(Shroud.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:kind, :string, allow_nil?: false, public?: true)
    attribute(:ciphertext, :string, allow_nil?: false, public?: true)
    attribute(:iv, :string, allow_nil?: false, public?: true)
    attribute(:ephemeral_public_key, :string, allow_nil?: false, public?: true)
    attribute(:sender_handle, :string, public?: true)
    attribute(:read_at, :utc_datetime_usec, public?: true)
    timestamps()
  end

  actions do
    defaults([:read, :destroy])

    create :deliver do
      accept([:kind, :ciphertext, :iv, :ephemeral_public_key, :sender_handle])
      primary?(true)
    end

    update :mark_read do
      accept([])
      change(set_attribute(:read_at, &DateTime.utc_now/0))
    end

    read :unread do
      filter(expr(is_nil(read_at)))
    end
  end

  code_interface do
    define(:deliver)
    define(:unread)
    define(:mark_read)
  end
end
