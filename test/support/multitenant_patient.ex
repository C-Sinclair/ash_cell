defmodule AshCell.Test.TenantPatient do
  @moduledoc """
  Resource declaring context multitenancy *without* `AshCell.Resource` — the shape a
  caller gets from the fork alone, plus a binder named by hand.

  `tenant_binder` is explicit here and must stay that way. Since ash_sqlite `76866fc`
  the option defaults to `AshSqlite.MultiTenancy.Binder` for any `strategy :context`
  resource, and that layer is never started in this suite, so leaving it unset does
  not fall back to "unbound" — it routes into a registry that does not exist and
  fails with `unknown registry: AshCell.TestRepo.TenantRegistry`. Naming the binder on
  resources that do not use the extension is what
  [ADR-22](../../docs/decisions/ADR-22-where-the-tenancy-runtime-lives.md) chose over
  adopting the fork's tenancy runtime, because that runtime evicts with no knowledge
  of a lease or a pending shipment and would break
  [ADR-09](../../docs/decisions/ADR-09-snapshot-before-releasing-the-lease.md) silently.

  `AshCell.Test.BoundPatient` is the same resource with the extension, which sets the
  same binder for you.
  """
  use Ash.Resource,
    domain: AshCell.Test.Domain,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "tenant_patients"
    repo AshCell.TestRepo
    tenant_binder AshCell.Binder
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
