defmodule Relay.Schema do
  @moduledoc """
  A stream cell's schema, applied before the cell serves anything.

  Almost all of it belongs to the library: `AshCell.Stream.Migration.up/0` creates the
  entry and meta tables. The demo adds one table of its own, for the prompt that
  started the generation — which is metadata *about* the stream rather than part
  of it, and so has no business being an entry in it.

  The migrations themselves are the files in `priv/cell_migrations`.
  """

  @doc "Where this demo's cell migrations are, for the fleet's `migrations_path:`."
  def migrations_path, do: Application.app_dir(:relay, "priv/cell_migrations")
end
