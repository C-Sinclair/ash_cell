defmodule AshCell.TestMigrations do
  @moduledoc "Versioned migrations for test cells."
  use AshCell.Migrator

  migration(1, """
  CREATE TABLE tenant_patients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL
  )
  """)

  migration(2, """
  CREATE TABLE patients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL
  )
  """)

  migration(3, fn repo_pid ->
    Ecto.Adapters.SQL.query!(repo_pid, "ALTER TABLE tenant_patients ADD COLUMN mrn TEXT", [])
  end)
end

defmodule AshCell.FailingMigrations do
  @moduledoc "Migrations whose last step fails, for quarantine tests."
  use AshCell.Migrator

  migration(1, """
  CREATE TABLE tenant_patients (id TEXT PRIMARY KEY, name TEXT NOT NULL)
  """)

  migration(2, "ALTER TABLE does_not_exist ADD COLUMN nope TEXT")
end

defmodule AshCell.PartialMigrations do
  @moduledoc "A truncated migration set, for testing forward upgrades in place."
  use AshCell.Migrator

  migration(1, """
  CREATE TABLE tenant_patients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL
  )
  """)
end
