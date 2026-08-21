# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :rollout,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :rollout, RolloutWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RolloutWeb.ErrorHTML, json: RolloutWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Rollout.PubSub,
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

config :rollout, ash_domains: [Rollout.Channel]

config :rollout, Rollout.CellRepo,
  # Every cell is an instance of this module started with its own database path,
  # so there is nothing to configure per channel here. pool_size stays at 1: the
  # cell is a single writer, and widening it measurably slows reads down
  # (ash_cell/scripts/read_pool_probe.exs).
  pool_size: 1,
  journal_mode: :wal,
  # Off so a benchmark measures the resolve path rather than the logger: one line
  # per query is a meaningful share of a 200 µs read.
  log: false

config :ash_cell,
  repo: Rollout.CellRepo,
  dir: "priv/cells",
  migrator: Rollout.Schema,
  max_resident: 64
