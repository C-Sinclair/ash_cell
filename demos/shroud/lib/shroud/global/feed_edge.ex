defmodule Shroud.Global.FeedEdge do
  @moduledoc """
  Denormalised `(viewer, owner, updated_at)` so a feed can be ordered and paged in
  Postgres before any cell is opened.

  This exists because of a hard constraint rather than a preference.
  Cross-data-layer relationships between global Postgres and a tenant cell support
  `load` only — no SQL-level filtering, sorting, or aggregating across the
  boundary. So anything the feed sorts or pages by has to be denormalised out of
  the cells and into Tier 0 at write time. `updated_at` is that: a timestamp, and
  deliberately nothing else. It reveals that Alice changed something and when,
  which is metadata we are not pretending to hide.

  Without this table, "show me the fifty most recently updated profiles I can see"
  would mean opening every cell just to find out which fifty to open.
  """
  use Ash.Resource,
    domain: Shroud.Global,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("feed_edges")
    repo(Shroud.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:profile_updated_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :viewer, Shroud.Global.User, allow_nil?: false
    belongs_to :owner, Shroud.Global.User, allow_nil?: false
  end

  identities do
    identity(:unique_edge, [:viewer_id, :owner_id])
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept([:viewer_id, :owner_id, :profile_updated_at])
      primary?(true)
      upsert?(true)
      upsert_identity(:unique_edge)
      upsert_fields([:profile_updated_at])
    end

    read :page_for_viewer do
      argument(:viewer_id, :uuid, allow_nil?: false)
      filter(expr(viewer_id == ^arg(:viewer_id)))
      prepare(build(sort: [profile_updated_at: :desc]))
      pagination(offset?: true, default_limit: 50, countable: true)
    end
  end

  code_interface do
    define(:upsert)
    define(:page_for_viewer, args: [:viewer_id])
  end
end
