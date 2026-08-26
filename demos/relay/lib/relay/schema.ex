defmodule Relay.Schema do
  @moduledoc """
  A stream cell's schema, applied before the cell serves anything.

  Almost all of it belongs to the library: `AshCell.Stream.migrate/1` creates the
  entry and meta tables. The demo adds one table of its own, for the prompt that
  started the generation — which is metadata *about* the stream rather than part
  of it, and so has no business being an entry in it.
  """
  use AshCell.Migrator

  migration(1, &AshCell.Stream.migrate/1)

  migration(2, """
  CREATE TABLE generation (
    id TEXT PRIMARY KEY,
    prompt TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    finished_at INTEGER
  )
  """)
end
