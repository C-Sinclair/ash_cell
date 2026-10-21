defmodule Region do
  @moduledoc """
  Organisations, projects, and tasks, each stored in the bucket of its region.

  Every cell call goes through a `Region.Scope`, which decides the cell key, and
  `Region.Stores` routes that key to its region's bucket.
  """

  alias Region.Accounts.Org
  alias Region.Scope
  alias Region.Work.{Project, Task}

  def create_org(name, home_region, allowed_regions),
    do: Org.create(name, home_region, allowed_regions)

  @doc """
  Creates a project, in its organisation's cell, or in its own cell when its region
  differs from the organisation's home region.

  A region outside the organisation's allowed regions is refused before any cell is
  opened.
  """
  def create_project(%Scope{org: org} = scope, attrs) do
    id = Ash.UUID.generate()
    region = Map.get(attrs, :region, org.home_region)
    project_scope = %{scope | project: %{id: id, region: region}}

    Project
    |> Ash.Changeset.for_create(:create, Map.merge(attrs, %{id: id, region: region}),
      scope: project_scope
    )
    |> Ash.create()
  end

  @doc "A scope for work inside `project`, routed to the project's cell."
  def project_scope(%Scope{} = scope, %Project{} = project), do: %{scope | project: project}

  def create_task(%Scope{project: %Project{id: project_id}} = scope, attrs) do
    Task
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :project_id, project_id), scope: scope)
    |> Ash.create()
  end

  def projects(%Scope{} = scope), do: Ash.read(Project, scope: scope)

  def tasks(%Scope{} = scope), do: Ash.read(Task, scope: scope)

  @doc "The cell key a scope routes to."
  def cell_key(%Scope{} = scope) do
    {:ok, key} = Ash.Scope.ToOpts.get_tenant(scope)
    key
  end
end
