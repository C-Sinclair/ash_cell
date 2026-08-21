defmodule Demo.Global.Clinic do
  @moduledoc """
  A tenant, in the global Postgres.

  The registry is deliberately global: you have to be able to list clinics
  *before* you know which cell to open, so this is the one thing that cannot live
  in a cell.
  """
  use Ash.Resource, domain: Demo.Global, data_layer: AshPostgres.DataLayer

  postgres do
    table "clinics"
    repo Demo.Repo
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :region, :string, public?: true
    attribute :plan, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:id, :name, :region, :plan], update: [:name, :region, :plan]]
  end

  code_interface do
    define :create
    define :read
    define :destroy
  end
end

defmodule Demo.Global do
  @moduledoc "Global domain: data shared across all clinics."
  use Ash.Domain

  resources do
    resource Demo.Global.Clinic
  end
end
