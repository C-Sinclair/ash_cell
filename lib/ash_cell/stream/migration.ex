defmodule AshCell.Stream.Migration do
  @moduledoc """
  The two tables `AshCell.Stream` needs, created from one of the fleet's own
  migration files, since the library does not own the fleet's migration list.

      defmodule MyApp.CellMigrations.AddStreams do
        use Ecto.Migration

        def up, do: AshCell.Stream.Migration.up()
      end
  """

  @doc "Creates the stream entry and meta tables. Call it from a migration's `up/0`."
  def up do
    Ecto.Migration.execute("""
    CREATE TABLE IF NOT EXISTS ash_cell_stream_entries (
      stream TEXT NOT NULL,
      seq INTEGER NOT NULL,
      payload BLOB NOT NULL,
      at INTEGER NOT NULL,
      PRIMARY KEY (stream, seq)
    )
    """)

    Ecto.Migration.execute("""
    CREATE TABLE IF NOT EXISTS ash_cell_stream_meta (
      stream TEXT PRIMARY KEY,
      flushed_through INTEGER NOT NULL DEFAULT 0,
      pending_start INTEGER,
      pending_end INTEGER,
      pending_digest TEXT
    )
    """)
  end
end
