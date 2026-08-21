defmodule Rollout.Channel.Promotion do
  @moduledoc """
  Append-only log of every pointer change: what it moved to, and why.

  In the cell rather than beside it, because a promotion and the pointer change it
  describes have to commit together — a log that can disagree with the pointer is
  worse than no log. That is also the one thing a cell can offer here that a shared
  database cannot do as cheaply: both rows are one file, one connection, one
  `BEGIN IMMEDIATE`.
  """
  use Ash.Resource,
    domain: Rollout.Channel,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("promotions")
    repo(Rollout.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:release_id, :uuid, public?: true)
    attribute(:from_release_id, :uuid, public?: true)
    attribute(:rollout, :integer, allow_nil?: false, public?: true)

    attribute(:kind, :atom,
      constraints: [one_of: [:promote, :rollback, :ramp]],
      allow_nil?: false,
      public?: true
    )

    attribute(:reason, :string, public?: true)
    create_timestamp(:inserted_at)
  end

  actions do
    defaults([:read, create: [:release_id, :from_release_id, :rollout, :kind, :reason]])
  end

  code_interface do
    define(:create)
    define(:read)
  end
end
