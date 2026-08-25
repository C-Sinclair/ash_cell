# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :branch,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :branch, BranchWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BranchWeb.ErrorHTML, json: BranchWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Branch.PubSub,
  live_view: [signing_salt: "SEIx/qZB"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

config :branch, Branch.CellRepo,
  # Every cell is an instance of this module started with its own database path,
  # so there is nothing to configure per channel here. pool_size stays at 1: the
  # cell is a single writer, and widening it measurably slows reads down
  # (ash_cell/scripts/read_pool_probe.exs).
  pool_size: 1,
  journal_mode: :wal,
  # Off so a benchmark measures the resolve path rather than the logger: one line
  # per query is a meaningful share of a 200 µs read.
  log: false

config :branch, Branch.CatalogRepo,
  database: "priv/catalog.db",
  # One connection, and a busy timeout, because this is SQLite: a wider pool just
  # moves contention from the pool queue to SQLite's write lock, where it surfaces
  # as "database is locked" instead of as waiting.
  pool_size: 1,
  busy_timeout: 5_000,
  journal_mode: :wal

config :branch, ecto_repos: [Branch.CatalogRepo]

# Branching reads and writes the snapshot history, so unlike the other demos this
# one cannot run without an object store. scripts/minio.sh in ash_cell starts one.
config :branch, :object_store,
  endpoint: "http://127.0.0.1:9010",
  bucket: "ashcell-branch",
  access_key_id: "ashcell",
  secret_access_key: "ashcellsecret"

config :ash_cell,
  repo: Branch.CellRepo,
  dir: "priv/cells",
  migrator: Branch.Schema,
  max_resident: 64
