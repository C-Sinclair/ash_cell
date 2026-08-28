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

defmodule AshCell.HandoffProbeMigrations do
  @moduledoc """
  Cells shaped like both halves of a record handoff, for `AshCell.HandoffProbeTest`.

  Separate from `AshCell.TestMigrations` for the same reason
  `AshCell.StreamMigrations` is: that set's version number is asserted by
  `test/migration_test.exs`, so appending here would break tests that have nothing
  to do with handoff.

  One migration set serves both cells. A source and a target differ by which tables
  they use, not by which tables they have, and giving them separate sets would mean
  a probe about ordering also had to be a probe about migration selection.
  """
  use AshCell.Migrator

  migration(1, """
  CREATE TABLE vault_notes (
    id TEXT PRIMARY KEY,
    body TEXT NOT NULL,
    handoff_state TEXT NOT NULL DEFAULT 'owned',
    handoff_id TEXT,
    promoted_to TEXT
  )
  """)

  migration(2, """
  CREATE TABLE imported_notes (
    id TEXT PRIMARY KEY,
    body TEXT NOT NULL
  )
  """)

  # The key the design settled on: the *record's* identity, not the attempt's.
  migration(3, """
  CREATE TABLE imports (
    source_cell TEXT NOT NULL,
    record_id TEXT NOT NULL,
    attempt_id TEXT NOT NULL,
    PRIMARY KEY (source_cell, record_id)
  )
  """)

  # The key that was proposed and is wrong, kept so the probe can show the
  # difference rather than assert it.
  migration(4, """
  CREATE TABLE imports_by_attempt (
    source_cell TEXT NOT NULL,
    record_id TEXT NOT NULL,
    attempt_id TEXT NOT NULL,
    PRIMARY KEY (source_cell, record_id, attempt_id)
  )
  """)
end
