defmodule Rollout.Channel.Pointer do
  @moduledoc """
  The one row that says what this channel serves right now.

  Singleton per cell, and the reason the cell exists. Every device check-in reads
  it; a promote or a rollback is a read-modify-write of it, which is exactly the
  operation that cannot be allowed to interleave — two nodes deciding what `prod`
  points at is the failure this architecture is chosen to make impossible.
  """
  use Ash.Resource,
    domain: Rollout.Channel,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("pointers")
    repo(Rollout.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  @singleton "pointer"

  def singleton_id, do: @singleton

  attributes do
    attribute(:id, :string,
      primary_key?: true,
      allow_nil?: false,
      default: @singleton,
      public?: true
    )

    attribute(:release_id, :uuid, public?: true)

    # Percentage of the fleet eligible, 0..100. Gating is a hash of the device id
    # against this, so a device gets a stable answer across retries and the read
    # path writes nothing.
    attribute(:rollout, :integer, default: 100, allow_nil?: false, public?: true)

    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, create: [:id, :release_id, :rollout]])

    update :point_at do
      accept([:release_id, :rollout])
      require_atomic?(true)
    end
  end

  code_interface do
    define(:read)
    define(:point_at)
  end
end
