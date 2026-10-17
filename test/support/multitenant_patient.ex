defmodule AshCell.Test.TenantPatient do
  @moduledoc """
  Resource declaring context multitenancy *without* `AshCell.Resource`.

  It needs nothing else to reach its cell: the binding is on the repo, which
  `use AshCell.Repo` makes a tenant repo. `AshCell.Test.BoundPatient` is the same
  resource with the extension, which adds a compile-time check and nothing at
  runtime.
  """
  use Ash.Resource,
    domain: AshCell.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "tenant_patients"
    repo AshCell.TestRepo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:name], update: [:name]]
  end

  code_interface do
    define :create, args: [:name]
    define :read
  end
end
