defmodule AshCell.TestMigrations do
  @moduledoc """
  The migration sets test cells open with, one directory each under
  `test/support/cell_migrations/`.

    * `:test` — the default. Its version, 3, is asserted by `test/migration_test.exs`,
      which is why the other sets are separate rather than appended to it.
    * `:stream` — only the durable-stream tables, for `AshCell.StreamTest`.
    * `:failing` — a last step that fails, for quarantine tests.
    * `:partial` — `:test` truncated to version 1, for upgrading a cell in place.
    * `:handoff_probe` — both halves of a record handoff, for
      `AshCell.HandoffProbeTest`. One set serves the source and the target, because
      they differ by which tables they use, not by which tables they have.
  """

  def path(set), do: Path.expand("cell_migrations/#{set}", __DIR__)
end
