defmodule AshCell.Test.Patient do
  @moduledoc "Probe resource. Deliberately plain: no aggregates, no transactions."
  use Ash.Resource,
    domain: AshCell.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "patients"
    repo AshCell.TestRepo
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
  end
end
