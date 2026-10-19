defmodule Demo.CellMigrations.IndexForeignKeys do
  use Ecto.Migration

  def up do
    execute("CREATE INDEX encounters_patient ON encounters(patient_id)")

    execute("CREATE INDEX observations_encounter ON observations(encounter_id)")
  end
end
