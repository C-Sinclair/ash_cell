defmodule Shroud.Profile.Grant do
  @moduledoc """
  "Audience `audience_slug` may read field `field_key`, and here is that field's
  content key wrapped under the audience's group key."

  This is the row that makes an offline owner readable. It is computed while the
  owner is online and then simply sits there; a reader who holds the group key can
  unwrap the content key without the owner participating. Nothing about a read
  requires the owner's presence, their master key, or their session.

  Revoking a field from an audience means deleting this row — which stops future
  reads and, as ever, cannot un-send what was already fetched.
  """
  use Ash.Resource,
    domain: Shroud.Profile,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("grants")
    repo(Shroud.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:field_key, :string, allow_nil?: false, public?: true)
    attribute(:audience_slug, :string, allow_nil?: false, public?: true)
    attribute(:wrapped_content_key, :string, allow_nil?: false, public?: true)
    attribute(:iv, :string, allow_nil?: false, public?: true)
    attribute(:generation, :integer, default: 1, allow_nil?: false, public?: true)
    timestamps()
  end

  identities do
    identity(:unique_grant, [:field_key, :audience_slug])
  end

  actions do
    defaults([:read, :destroy])

    create :put do
      accept([:field_key, :audience_slug, :wrapped_content_key, :iv, :generation])
      primary?(true)
      upsert?(true)
      upsert_identity(:unique_grant)
      upsert_fields([:wrapped_content_key, :iv, :generation])
    end

    read :for_audiences do
      argument(:slugs, {:array, :string}, allow_nil?: false)
      filter(expr(audience_slug in ^arg(:slugs)))
    end
  end

  code_interface do
    define(:put)
    define(:for_audiences, args: [:slugs])
    define(:read, action: :read)
  end
end
