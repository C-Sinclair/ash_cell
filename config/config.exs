import Config

config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false

config :ash_cell, ecto_repos: [AshCell.TestRepo]

config :ash_cell, AshCell.TestRepo,
  database: Path.join(__DIR__, "../tmp/default.db"),
  pool_size: 1,
  migration_lock: false,
  migration_primary_key: [name: :id, type: :binary_id]

config :ash_cell, :object_store,
  endpoint: "http://127.0.0.1:9010",
  bucket: "ashcell-test",
  access_key_id: "ashcell",
  secret_access_key: "ashcellsecret"

if config_env() == :test do
  config :logger, level: :warning
end
