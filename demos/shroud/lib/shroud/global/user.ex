defmodule Shroud.Global.User do
  @moduledoc """
  An account. Tier 0 only — there is nothing private here.

  `handle` is deliberately server-visible: it is how one user finds another, and a
  searchable-encryption scheme good enough to keep it private is out of scope (see
  the non-goals in `docs/prd.md`). Anything a user would not want the server to
  read belongs in their cell as a `Shroud.Profile.Field`.

  `public_key` is an ECDH P-256 public key, published so that anyone — another
  user, or the server on behalf of a background job — can seal a payload *to* this
  user without being able to read anything *of* theirs. That is what makes writes
  to an offline user possible.

  `shredded_at` records that the key wraps are gone. The row survives so that
  other users' audience memberships and feed edges still resolve to something
  rather than dangling.
  """
  use Ash.Resource,
    domain: Shroud.Global,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("users")
    repo(Shroud.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:handle, :string, allow_nil?: false, public?: true)
    attribute(:display_hint, :string, public?: true)
    attribute(:public_key, :string, public?: true)
    attribute(:shredded_at, :utc_datetime_usec, public?: true)
    timestamps()
  end

  identities do
    identity(:unique_handle, [:handle])
  end

  relationships do
    has_many :credentials, Shroud.Global.Credential
    has_many :key_wraps, Shroud.Global.KeyWrap
  end

  calculations do
    calculate(:shredded?, :boolean, expr(not is_nil(shredded_at)))
  end

  actions do
    defaults([:read, :destroy])

    create :register do
      accept([:handle, :display_hint, :public_key])
      primary?(true)
    end

    update :set_public_key do
      accept([:public_key])
    end

    update :mark_shredded do
      accept([])
      change(set_attribute(:shredded_at, &DateTime.utc_now/0))
    end
  end

  code_interface do
    define(:register, args: [:handle])
    define(:read, action: :read)
    define(:mark_shredded)
  end
end
