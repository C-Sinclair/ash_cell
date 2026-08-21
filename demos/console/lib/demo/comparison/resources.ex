defmodule Demo.Comparison.PgPatient do
  @moduledoc """
  The Postgres half of the comparison, as **Ash resources**.

  The first version of this benchmark timed Ash-on-SQLite against hand-written
  Ecto SQL, which is not a comparison of data layers — it is a comparison of
  "with Ash" against "without Ash", and Ash's query building and struct
  materialisation dominated the result.

  Both sides now run the identical `Ash.Query.load/2` through the identical
  framework, so the only variable left is where the bytes live.
  """
  use Ash.Resource, domain: Demo.Comparison, data_layer: AshPostgres.DataLayer

  postgres do
    table "pg_patients"
    repo Demo.Repo
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :clinic_id, :string, public?: true
    attribute :name, :string, public?: true
    attribute :mrn, :string, public?: true
    attribute :birth_year, :integer, public?: true
    attribute :risk_score, :integer, public?: true
  end

  relationships do
    has_many :encounters, Demo.Comparison.PgEncounter, destination_attribute: :patient_id
  end

  actions do
    defaults [:read]
  end
end

defmodule Demo.Comparison.PgEncounter do
  @moduledoc false
  use Ash.Resource, domain: Demo.Comparison, data_layer: AshPostgres.DataLayer

  postgres do
    table "pg_encounters"
    repo Demo.Repo
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :clinic_id, :string, public?: true
    attribute :reason, :string, public?: true
    attribute :occurred_on, :date, public?: true
  end

  relationships do
    belongs_to :patient, Demo.Comparison.PgPatient, attribute_type: :uuid
    has_many :observations, Demo.Comparison.PgObservation, destination_attribute: :encounter_id
  end

  actions do
    defaults [:read]
  end
end

defmodule Demo.Comparison.PgObservation do
  @moduledoc false
  use Ash.Resource, domain: Demo.Comparison, data_layer: AshPostgres.DataLayer

  postgres do
    table "pg_observations"
    repo Demo.Repo
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :clinic_id, :string, public?: true
    attribute :code, :string, public?: true
    attribute :value, :integer, public?: true
  end

  relationships do
    belongs_to :encounter, Demo.Comparison.PgEncounter, attribute_type: :uuid
  end

  actions do
    defaults [:read]
  end
end

defmodule Demo.Comparison do
  @moduledoc "Like-for-like Postgres resources, used only for benchmarking."
  use Ash.Domain

  resources do
    resource Demo.Comparison.PgPatient
    resource Demo.Comparison.PgEncounter
    resource Demo.Comparison.PgObservation
  end
end
