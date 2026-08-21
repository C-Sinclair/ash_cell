defmodule Shroud.Global.PostRef do
  @moduledoc """
  A Tier 0 pointer to a post, so a timeline can be ordered and paged in Postgres.

  Same reasoning as `Shroud.Global.FeedEdge`, and for the same hard constraint: there
  is no query that spans cells, so "the fifty most recent posts I can see" cannot be
  answered by the cells themselves without opening all of them. This table answers
  *which* fifty, and then exactly those cells get opened.

  It holds no content — author, post id, visibility, timestamp. For a private post
  that is the complete extent of what the server learns: that this author posted
  something to this audience at this time. Metadata, and we are not claiming to hide
  it.
  """
  use Ash.Resource,
    domain: Shroud.Global,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("post_refs")
    repo(Shroud.Repo)

    references do
      reference(:author, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:post_id, :uuid, allow_nil?: false, public?: true)
    attribute(:visibility, :string, allow_nil?: false, public?: true)
    attribute(:posted_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :author, Shroud.Global.User, allow_nil?: false
  end

  identities do
    identity(:unique_post, [:post_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:post_id, :visibility, :posted_at, :author_id])
      primary?(true)
    end

    read :public_timeline do
      filter(expr(visibility == "public"))
      prepare(build(sort: [posted_at: :desc], limit: 200))
    end

    read :for_author do
      argument(:author_id, :uuid, allow_nil?: false)
      filter(expr(author_id == ^arg(:author_id)))
      prepare(build(sort: [posted_at: :desc], limit: 200))
    end

    # Posts by these authors, restricted to these audiences. The pair has to be
    # checked together: being in Alice's "Friends" must not reveal her "Family" posts.
    read :for_memberships do
      argument(:pairs, {:array, :map}, allow_nil?: false)

      prepare(fn query, _ctx ->
        pairs = Ash.Query.get_argument(query, :pairs)

        filter =
          Enum.reduce(pairs, false, fn %{author_id: author_id, slugs: slugs}, acc ->
            expr(^acc or (author_id == ^author_id and visibility in ^slugs))
          end)

        query
        |> Ash.Query.do_filter(filter)
        |> Ash.Query.sort(posted_at: :desc)
        |> Ash.Query.limit(200)
      end)
    end
  end

  code_interface do
    define(:create)
    define(:public_timeline)
    define(:for_author, args: [:author_id])
    define(:for_memberships, args: [:pairs])
  end
end
