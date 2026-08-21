defmodule Shroud.Global.AudienceMember do
  @moduledoc """
  "`member` is in `owner`'s audience `audience_id`, and here is that audience's
  group key sealed to `member`'s public key."

  Tier 0 by necessity and Tier 1 in substance, which is the interesting part. The
  server can see *that* Bob is in Alice's Friends list — the graph is not private
  here — but `wrapped_group_key` is sealed to Bob's ECDH public key, so only Bob
  can turn it into the group key.

  ## Why a group key at all

  Without this indirection, sharing one field with 500 followers means 500 wraps,
  and adding a follower means re-wrapping every field. With it, a field's content
  key is wrapped once under the group key, and joining an audience is one wrap of
  the group key. Share cost becomes O(audiences), not O(followers).

  The bill arrives on removal: revoking a member means rotating the group key and
  re-wrapping for everyone who remains. That is the expensive operation in this
  design, and in every other design too.
  """
  use Ash.Resource,
    domain: Shroud.Global,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("audience_members")
    repo(Shroud.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:audience_id, :string, allow_nil?: false, public?: true)
    attribute(:wrapped_group_key, :string, allow_nil?: false, public?: true)
    attribute(:ephemeral_public_key, :string, allow_nil?: false, public?: true)
    attribute(:iv, :string, allow_nil?: false, public?: true)
    attribute(:generation, :integer, default: 1, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :owner, Shroud.Global.User, allow_nil?: false
    belongs_to :member, Shroud.Global.User, allow_nil?: false
  end

  identities do
    identity(:unique_membership, [:owner_id, :audience_id, :member_id, :generation])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :audience_id,
        :wrapped_group_key,
        :ephemeral_public_key,
        :iv,
        :generation,
        :owner_id,
        :member_id
      ])

      primary?(true)
    end

    read :for_member do
      argument(:member_id, :uuid, allow_nil?: false)
      filter(expr(member_id == ^arg(:member_id)))
    end

    read :for_audience do
      argument(:owner_id, :uuid, allow_nil?: false)
      argument(:audience_id, :string, allow_nil?: false)
      filter(expr(owner_id == ^arg(:owner_id) and audience_id == ^arg(:audience_id)))
    end
  end

  code_interface do
    define(:create)
    define(:for_member, args: [:member_id])
    define(:for_audience, args: [:owner_id, :audience_id])
  end
end
