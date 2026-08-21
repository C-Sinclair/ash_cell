# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :shroud,
  ecto_repos: [Shroud.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :shroud, ShroudWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ShroudWeb.ErrorHTML, json: ShroudWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Shroud.PubSub,
  live_view: [signing_salt: "StVbwdx8"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  shroud: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  shroud: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Default cell directory. Deliberately set BEFORE import_config: it used to be set
# after, which silently overrode the test config and pointed the test suite at the dev
# fleet's cells -- a test that destroys a cell key could then destroy a real one.
config :shroud, :cell_dir, "priv/cells"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

config :shroud, ecto_repos: [Shroud.Repo]
config :shroud, :ash_domains, [Shroud.Global, Shroud.Profile]

config :shroud, Shroud.CellRepo, pool_size: 1, migration_lock: false

config :shroud, :object_store,
  endpoint: "http://127.0.0.1:9010",
  bucket: "ashcell-shroud",
  access_key_id: "ashcell",
  secret_access_key: "ashcellsecret"

config :ash, :validate_domain_config_inclusion?, false
