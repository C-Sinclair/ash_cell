defmodule Shroud.Profile.Post do
  @moduledoc """
  A post, in its author's cell.

  ## Public posts are plaintext, deliberately

  "Public" and "the server cannot read it" are contradictory requirements. A public
  post encrypted under a key every reader holds is not protected from anything — the
  server can join the crowd and read it. So a public post stores `body` in the clear
  (Tier 0, still SQLCipher-encrypted at rest) and an audience post stores
  `ciphertext` (Tier 1, opaque to us).

  Pretending otherwise would be the dishonest choice, and the split turns out to be
  the most legible thing in the app: it is *because* public posts are server-readable
  that they can be indexed and sorted globally in Postgres, and *because* private
  posts are not that they cannot. The tier split is not a compromise here, it is the
  mechanism.

  ## Two wraps per private post

  `wrapped_content_key` is the post's content key under the audience's group key —
  what a reader uses. `own_wrapped_content_key` is the same content key under the
  author's master key — what the author uses. Both are needed: without the second,
  an author can publish a post and then be unable to read it back, which is an easy
  and very confusing bug to ship.
  """
  use Ash.Resource,
    domain: Shroud.Profile,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("posts")
    repo(Shroud.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)

    # Tier 0: "public", or an audience slug. The server needs this to decide who may
    # be handed the row at all, which it cannot do by reading the body.
    attribute(:visibility, :string, allow_nil?: false, public?: true)

    # Public posts only.
    attribute(:body, :string, public?: true)

    # Audience posts only.
    attribute(:ciphertext, :string, public?: true)
    attribute(:iv, :string, public?: true)
    attribute(:content_key_id, :string, public?: true)
    attribute(:wrapped_content_key, :string, public?: true)
    attribute(:wrap_iv, :string, public?: true)
    attribute(:own_wrapped_content_key, :string, public?: true)
    attribute(:own_wrap_iv, :string, public?: true)

    attribute(:posted_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )
  end

  calculations do
    calculate(:public?, :boolean, expr(visibility == "public"))
  end

  actions do
    defaults([:read, :destroy])

    create :publish do
      accept([
        :visibility,
        :body,
        :ciphertext,
        :iv,
        :content_key_id,
        :wrapped_content_key,
        :wrap_iv,
        :own_wrapped_content_key,
        :own_wrap_iv
      ])

      primary?(true)
      change(set_attribute(:posted_at, &DateTime.utc_now/0))
    end

    read :by_ids do
      argument(:ids, {:array, :uuid}, allow_nil?: false)
      filter(expr(id in ^arg(:ids)))
      prepare(build(sort: [posted_at: :desc]))
    end

    read :recent do
      prepare(build(sort: [posted_at: :desc], limit: 50))
    end
  end

  code_interface do
    define(:publish)
    define(:by_ids, args: [:ids])
    define(:recent)
    define(:read, action: :read)
  end
end
