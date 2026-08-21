defmodule Demo.Clinical.Patient do
  @moduledoc """
  Clinical data, in a per-clinic cell.

  Note what is *not* here: no `clinic_id` column, and no filter on one. The clinic
  is the database. There is no shared table for a missing `WHERE` clause to leak
  across.
  """
  use Ash.Resource,
    domain: Demo.Clinical,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("patients")
    repo(Demo.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:mrn, :string, public?: true)
    attribute(:birth_year, :integer, public?: true)
    attribute(:risk_score, :integer, public?: true, default: 0)
  end

  relationships do
    has_many :encounters, Demo.Clinical.Encounter
  end

  actions do
    defaults([
      :read,
      :destroy,
      create: [:name, :mrn, :birth_year, :risk_score],
      update: [:name, :mrn, :birth_year, :risk_score]
    ])
  end

  code_interface do
    define(:create)
    define(:read)
    define(:update)
    define(:destroy)
    define(:get_by_id, action: :read, get_by: [:id])
  end
end

defmodule Demo.Clinical.Encounter do
  @moduledoc "A visit. Joins to patients are ordinary SQL joins inside one cell."
  use Ash.Resource,
    domain: Demo.Clinical,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("encounters")
    repo(Demo.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:reason, :string, public?: true)
    attribute(:occurred_on, :date, public?: true)
  end

  relationships do
    belongs_to :patient, Demo.Clinical.Patient, attribute_type: :uuid
    has_many :observations, Demo.Clinical.Observation
  end

  actions do
    defaults([:read, :destroy, create: [:reason, :occurred_on, :patient_id], update: [:reason]])
  end

  code_interface do
    define(:create)
    define(:read)
  end
end

defmodule Demo.Clinical.Observation do
  @moduledoc "A measurement taken during an encounter."
  use Ash.Resource,
    domain: Demo.Clinical,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshCell.Resource]

  sqlite do
    table("observations")
    repo(Demo.CellRepo)
  end

  multitenancy do
    strategy(:context)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:code, :string, public?: true)
    attribute(:value, :integer, public?: true)
  end

  relationships do
    belongs_to :encounter, Demo.Clinical.Encounter, attribute_type: :uuid
  end

  actions do
    defaults([:read, :destroy, create: [:code, :value, :encounter_id]])
  end

  code_interface do
    define(:create)
    define(:read)
  end
end

defmodule Demo.Clinical do
  @moduledoc """
  Clinical domain. Every resource here is tenanted, and every one of them lives in
  the calling clinic's own database.
  """
  use Ash.Domain

  resources do
    resource(Demo.Clinical.Patient)
    resource(Demo.Clinical.Encounter)
    resource(Demo.Clinical.Observation)
  end
end
