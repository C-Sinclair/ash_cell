import Config

config :collab_editor, generators: [timestamp_type: :utc_datetime]

config :collab_editor, CollabEditorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CollabEditorWeb.ErrorHTML, json: CollabEditorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CollabEditor.PubSub,
  live_view: [signing_salt: "0hK2pWqv"]

config :esbuild,
  version: "0.17.11",
  collab_editor: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" =>
        Enum.join(
          [Path.expand("../deps", __DIR__), Path.expand("../assets/node_modules", __DIR__)],
          ":"
        )
    }
  ]

config :tailwind,
  version: "3.4.3",
  collab_editor: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# One cell per *document*, not per tenant. This is the whole point of the demo.
config :collab_editor, :ash_domains, [CollabEditor.Docs]
config :ash_cell, cell_key: CollabEditor.CellKey

config :collab_editor, CollabEditor.CellRepo, pool_size: 1, migration_lock: false
config :collab_editor, :cell_dir, "priv/cells"

# Snapshots and restore are optional here — the demo runs without MinIO, it just
# cannot show the object-store panel.
config :collab_editor, :object_store,
  endpoint: "http://127.0.0.1:9010",
  bucket: "ashcell-collab",
  access_key_id: "ashcell",
  secret_access_key: "ashcellsecret"

config :ash, :validate_domain_config_inclusion?, false

import_config "#{config_env()}.exs"
