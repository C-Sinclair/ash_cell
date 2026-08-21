defmodule Rollout.Channel.Release do
  @moduledoc "A candidate build: a version, its notes, and the state it is in."
  use Ash.Resource,
    domain: Rollout.Channel,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("releases")
    repo(Rollout.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:notes, :string, public?: true)

    attribute(:state, :atom,
      constraints: [one_of: [:draft, :live, :superseded, :rolled_back]],
      default: :draft,
      allow_nil?: false,
      public?: true
    )

    create_timestamp(:inserted_at)
  end

  relationships do
    has_many(:artifacts, Rollout.Channel.Artifact)
  end

  actions do
    defaults([:read, :destroy, create: [:version, :notes], update: [:notes]])

    update :set_state do
      accept([:state])
      require_atomic?(true)
    end
  end

  code_interface do
    define(:create, args: [:version])
    define(:read)
    define(:set_state, args: [:state])
  end
end
