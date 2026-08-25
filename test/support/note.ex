defmodule AshCell.Test.Note do
  @moduledoc """
  A resource that is not a cell: one shared table, no tenant, its own repo module.

  Deliberately *not* using `AshCell.Resource` — that extension requires
  `strategy :context`, because a cell is one database per tenant and the tenant is
  how it finds which one. This is the other shape: `write_transactions?` comes from the
  `sqlite` section directly, and nothing binds anything.
  """
  use Ash.Resource,
    domain: AshCell.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "notes"
    repo AshCell.TestGlobalRepo
    write_transactions? true
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:body]]

    create :create_then_fail do
      accept [:body]

      change after_action(fn _changeset, _record, _context ->
               {:error,
                Ash.Error.Changes.InvalidAttribute.exception(field: :body, message: "deliberate")}
             end)
    end
  end

  code_interface do
    define :create, args: [:body]
    define :create_then_fail, args: [:body]
    define :read
  end
end
