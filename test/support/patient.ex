defmodule AshCell.Test.Patient do
  @moduledoc """
  Probe resource. Deliberately plain: no aggregates, no transactions, no tenancy.

  On `AshCell.TestProbeRepo` rather than the cells' repo, because a tenant repo
  only serves `strategy :context` resources.
  """
  use Ash.Resource,
    domain: AshCell.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "patients"
    repo AshCell.TestProbeRepo
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

defmodule AshCell.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshCell.Test.Patient
    resource AshCell.Test.TenantPatient
    resource AshCell.Test.BoundPatient
    resource AshCell.Test.Note
  end
end
