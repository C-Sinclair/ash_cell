defmodule Shroud.Profile.Audience do
  @moduledoc """
  A named group — Friends, Family, Public — and its group key wrapped under the
  owner's master key.

  The owner's copy of the group key lives here, in the owner's cell, sealed under
  MK. Each *member's* copy lives in `Shroud.Global.AudienceMember`, sealed to that
  member's public key. Two wraps of the same key for two different readers, which
  is what lets an offline owner's audience still be readable: the members' wraps
  were computed at share time and do not need the owner present.

  `generation` bumps on rotation. Removing a member mints a new group key, so the
  old generation's wraps stop being useful for anything encrypted afterwards —
  though, unavoidably, not for what the removed member already fetched.
  """
  use Ash.Resource,
    domain: Shroud.Profile,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("audiences")
    repo(Shroud.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:slug, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:wrapped_group_key, :string, allow_nil?: false, public?: true)
    attribute(:iv, :string, allow_nil?: false, public?: true)
    attribute(:generation, :integer, default: 1, allow_nil?: false, public?: true)
    timestamps()
  end

  identities do
    identity(:unique_slug, [:slug])
  end

  actions do
    defaults([:read, :destroy])

    create :put do
      accept([:slug, :name, :wrapped_group_key, :iv, :generation])
      primary?(true)
      upsert?(true)
      upsert_identity(:unique_slug)
      upsert_fields([:name, :wrapped_group_key, :iv, :generation])
    end

    read :by_slug do
      argument(:slug, :string, allow_nil?: false)
      get?(true)
      filter(expr(slug == ^arg(:slug)))
    end
  end

  code_interface do
    define(:put)
    define(:by_slug, args: [:slug])
    define(:read, action: :read)
  end
end
