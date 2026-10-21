defmodule Region.Scope do
  @moduledoc """
  The actor, organisation, and optionally project an action runs for.

  `Ash.Scope.ToOpts.get_tenant/1` on this struct is the only code that builds a cell
  key. Callers pass `scope:` and never `tenant:`, so a cell's region always comes from
  the global `Region.Accounts.Org` row, or from a project whose region differs from it.
  """
  @enforce_keys [:org]
  defstruct [:actor, :org, :project]

  @type t :: %__MODULE__{actor: term(), org: Region.Accounts.Org.t(), project: map() | nil}

  defimpl Ash.Scope.ToOpts do
    def get_actor(%{actor: actor}), do: {:ok, actor}

    def get_tenant(%{org: org, project: %{region: region, id: project_id}})
        when region != org.home_region,
        do: {:ok, "#{region}:#{org.id}:#{project_id}"}

    def get_tenant(%{org: org}), do: {:ok, "#{org.home_region}:#{org.id}"}

    def get_context(%{org: org}), do: {:ok, %{region: %{org: org}}}
    def get_tracer(_), do: :error
    def get_authorize?(_), do: :error
  end
end
