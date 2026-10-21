defmodule Region.Work do
  @moduledoc """
  The cell side: projects and their tasks, in the cell of the organisation or project
  the caller's `Region.Scope` names.
  """
  use Ash.Domain

  resources do
    resource(Region.Work.Project)
    resource(Region.Work.Task)
  end
end

defmodule Region.Work.Project do
  @moduledoc """
  A project, with the region its data is stored in.

  `region` is denormalised from the global side so a cell can be read without the
  global store.
  """
  use Ash.Resource,
    domain: Region.Work,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("projects")
    repo(Region.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    # Writable because a project in its own region is keyed by its id, so the id
    # has to exist before the cell it is created in.
    uuid_primary_key(:id, writable?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:region, :string, allow_nil?: false, public?: true)
  end

  relationships do
    has_many(:tasks, Region.Work.Task)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:id, :name, :region])
      validate(Region.Work.RegionAllowed)
    end
  end
end

defmodule Region.Work.Task do
  @moduledoc "A unit of work in a project."
  use Ash.Resource,
    domain: Region.Work,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("tasks")
    repo(Region.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:status, :string, allow_nil?: false, default: "open", public?: true)
  end

  relationships do
    belongs_to(:project, Region.Work.Project, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: [:title, :status, :project_id]])
  end
end

defmodule Region.Work.RegionAllowed do
  @moduledoc """
  Refuses a project whose region is not one of its organisation's allowed regions.

  Reads the organisation from the `Region.Scope` context, and runs before the data
  layer asks for a connection, so a refused project opens no cell.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    region = Ash.Changeset.get_attribute(changeset, :region)

    case get_in(changeset.context, [:region, :org]) do
      nil ->
        {:error, field: :region, message: "needs a Region.Scope carrying the organisation"}

      %{allowed_regions: allowed} ->
        if region in allowed,
          do: :ok,
          else:
            {:error,
             field: :region,
             message: "%{region} is not one of the organisation's allowed regions",
             vars: [region: region]}
    end
  end
end
