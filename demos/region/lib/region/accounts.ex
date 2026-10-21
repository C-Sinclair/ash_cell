defmodule Region.Accounts do
  @moduledoc """
  The global side: organisations and the regions each one may store data in.
  """
  use Ash.Domain

  resources do
    resource(Region.Accounts.Org)
  end

  @doc "Creates the global tables. The global store is not a cell, so no cell migration runs here."
  def migrate do
    Ecto.Adapters.SQL.query!(
      Region.GlobalRepo,
      """
      CREATE TABLE IF NOT EXISTS orgs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        home_region TEXT NOT NULL,
        allowed_regions TEXT NOT NULL
      )
      """,
      []
    )

    :ok
  end
end

defmodule Region.Accounts.Org do
  @moduledoc "An organisation, the region its data lives in, and the regions a project may choose."
  use Ash.Resource,
    domain: Region.Accounts,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("orgs")
    repo(Region.GlobalRepo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:home_region, :string, allow_nil?: false, public?: true)
    attribute(:allowed_regions, {:array, :string}, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:name, :home_region, :allowed_regions])

      validate(fn changeset, _context ->
        home = Ash.Changeset.get_attribute(changeset, :home_region)
        allowed = Ash.Changeset.get_attribute(changeset, :allowed_regions) || []

        if home in allowed,
          do: :ok,
          else: {:error, field: :home_region, message: "must be one of the allowed regions"}
      end)
    end
  end

  code_interface do
    define(:create, args: [:name, :home_region, :allowed_regions])
  end
end
