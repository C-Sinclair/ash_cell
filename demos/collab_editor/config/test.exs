import Config

config :collab_editor, CollabEditorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7ZOgYUcN22Ei30Ep/yym2uwKgvrvRme2lt6QqzKaI+fr5aBKQUYTbMnz2rC87RTs",
  server: false

# Cells for the test run live outside priv/, so a test never eats a document you
# were editing in dev.
config :collab_editor, :cell_dir, "tmp/test_cells"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view, enable_expensive_runtime_checks: true
