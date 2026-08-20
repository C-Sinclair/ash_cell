defmodule AshCell.Test.BoundPatient do
  @moduledoc """
  The same resource as `AshCell.Test.TenantPatient`, plus `AshCell.Resource`.

  Shares its table, so a test can write through one and read through the other and
  see that the extension changes only *who binds*, not where the rows land.
  """
  use Ash.Resource,
    domain: AshCell.Test.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

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
    defaults [:read, :destroy, create: [:name]]

    create :create_then_fail do
      accept [:name]

      change after_action(fn _changeset, _record, _context ->
               {:error,
                Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: "deliberate")}
             end)
    end

    update :rename do
      require_atomic? true
      accept [:name]
    end
  end

  code_interface do
    define :create, args: [:name]
    define :create_then_fail, args: [:name]
    define :read
    define :rename, args: [:name]
  end
end
