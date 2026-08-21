import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :rollout, RolloutWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "RfkQVRBkoqomp9La4AdT2qK/oBSeH+MALVuyuM1i5WoTZHFxiM71BSlMgwfMvprR",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Cells under the build directory, so a test run leaves nothing in priv/.
config :ash_cell, dir: Path.expand("../_build/test/cells", __DIR__)
