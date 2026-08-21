import Config

config :vcs, :ash_domains, [Vcs.Store]

# One connection per cell. A repository is a single-writer object, and the pool size is
# where that stops being a metaphor.
config :vcs, Vcs.CellRepo, pool_size: 1, migration_lock: false

config :vcs, :cell_dir, "priv/cells"

config :vcs, VcsWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [formats: [json: VcsWeb.ErrorJSON], layout: false],
  secret_key_base: String.duplicate("vcs-poc-not-a-secret", 4),
  server: true

config :phoenix, :json_library, Jason

config :logger, level: :info

import_config "#{config_env()}.exs"
