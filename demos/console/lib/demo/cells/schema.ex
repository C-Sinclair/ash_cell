defmodule Demo.Cells.Schema do
  @moduledoc """
  Versioned schema for a clinic's cell, applied on activation before the cell
  serves traffic.

  Migration here is a *fleet* operation: there is no moment at which every clinic
  is on the same schema. The mitigation is that a failure takes down one clinic
  rather than all of them, and that failures are recorded (see
  `AshCell.Manager.quarantined/0`) instead of merely logged into the night.

  Run `mix ash_cell.migrate --tenants ...` at deploy time so failures surface
  while somebody is watching. Lazy activation is the fallback, not the plan.
  """
  use AshCell.Migrator

  migration(1, """
  CREATE TABLE patients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    mrn TEXT,
    birth_year INTEGER,
    risk_score INTEGER DEFAULT 0
  )
  """)

  migration(2, """
  CREATE TABLE encounters (
    id TEXT PRIMARY KEY,
    patient_id TEXT,
    reason TEXT,
    occurred_on TEXT
  )
  """)

  migration(3, """
  CREATE TABLE observations (
    id TEXT PRIMARY KEY,
    encounter_id TEXT,
    code TEXT,
    value INTEGER
  )
  """)

  migration(4, fn repo_pid ->
    for sql <- [
          "CREATE INDEX encounters_patient ON encounters(patient_id)",
          "CREATE INDEX observations_encounter ON observations(encounter_id)"
        ] do
      Ecto.Adapters.SQL.query!(repo_pid, sql, [])
    end
  end)
end
