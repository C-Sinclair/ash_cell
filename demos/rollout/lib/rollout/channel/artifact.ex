defmodule Rollout.Channel.Artifact do
  @moduledoc """
  One blob reference, plus the client it is for.

  The blob itself is never here. It is content-addressed in the object store under
  its hash, immutable, and served straight to the device — so this row is a
  *pointer to bytes*, a few hundred of them, and the cell stays small enough to be
  a coordination point rather than a data store.

  Compatibility is stored as plain columns because the resolve path filters on them
  and AshSqlite has no aggregates: everything the read path needs has to be
  expressible as a filter or an expression calculation.
  """
  use Ash.Resource,
    domain: Rollout.Channel,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("artifacts")
    repo(Rollout.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:blob_hash, :string, allow_nil?: false, public?: true)

    attribute(:kind, :atom,
      constraints: [one_of: [:bundle, :asset, :sourcemap]],
      allow_nil?: false,
      public?: true
    )

    attribute(:platform, :atom,
      constraints: [one_of: [:ios, :android]],
      allow_nil?: false,
      public?: true
    )

    attribute(:arch, :string, allow_nil?: false, public?: true)
    attribute(:size, :integer, allow_nil?: false, public?: true)

    # Inclusive lower bound, exclusive upper. Encoded as integers because a device
    # sends "1.4.2" and the resolve path must not pay for parsing on every read.
    attribute(:min_runtime, :integer, allow_nil?: false, public?: true)
    attribute(:max_runtime, :integer, public?: true)
  end

  relationships do
    belongs_to(:release, Rollout.Channel.Release, allow_nil?: false, public?: true)
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [
        :blob_hash,
        :kind,
        :platform,
        :arch,
        :size,
        :min_runtime,
        :max_runtime,
        :release_id
      ]
    ])
  end

  code_interface do
    define(:create)
    define(:read)
  end
end
