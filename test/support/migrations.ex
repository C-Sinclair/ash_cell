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

defmodule AshCell.StreamMigrations do
  @moduledoc """
  Cells with only the durable-stream tables, for `AshCell.StreamTest`.

  Separate from `AshCell.TestMigrations` rather than appended to it: that set's
  version number is asserted by `test/migration_test.exs`, so adding a step there
  breaks three tests that have nothing to do with streams.
  """
  use AshCell.Migrator

  migration(1, &AshCell.Stream.migrate/1)
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
