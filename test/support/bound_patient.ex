defmodule AshCell.Test.BoundPatient do
  @moduledoc """
  The same resource as `AshCell.Test.TenantPatient`, plus `AshCell.Resource`.

  Shares its table, so a test can write through one and read through the other and
  see that the extension changes only *who binds*, not where the rows land.
  """
  use Ash.Resource,
    domain: AshCell.Test.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource],
    simple_notifiers: [AshCell.Test.Notifier]

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

    # Two inserts in one action, the second from an after_action hook, so both are
    # inside the transaction Ash opens for the action. `fail?` fails it after both.
    # The hook reports what it saw, because what is bound *inside* the transaction
    # is the thing under test.
    create :create_pair do
      accept [:name]
      argument :fail?, :boolean, default: false
      argument :report_to, :term

      change after_action(fn changeset, record, _context ->
               send(
                 Ash.Changeset.get_argument(changeset, :report_to),
                 {:inside, AshCell.bound_cell(), AshCell.in_transaction?()}
               )

               Ash.create!(AshCell.Test.BoundPatient, %{name: record.name <> " pair"},
                 tenant: changeset.tenant
               )

               if Ash.Changeset.get_argument(changeset, :fail?) do
                 {:error,
                  Ash.Error.Changes.InvalidAttribute.exception(
                    field: :name,
                    message: "deliberate"
                  )}
               else
                 {:ok, record}
               end
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
