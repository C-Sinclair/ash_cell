import Config

config :ash, :default_string_length_count, :codepoints

config :region, ash_domains: [Region.Accounts, Region.Work]

config :region, Region.CellRepo,
  # One writer per cell; widening the pool measurably slows reads
  # (ash_cell/scripts/read_pool_probe.exs).
  pool_size: 1,
  journal_mode: :wal,
  log: false

config :region, Region.GlobalRepo,
  database: "priv/global.db",
  pool_size: 1,
  busy_timeout: 5_000,
  journal_mode: :wal

config :region, ecto_repos: [Region.GlobalRepo]

# Every region is a bucket on one endpoint. Two buckets on one MinIO stand in for two
# locations; they prove the routing, not the geography.
config :region, :object_store,
  endpoint: "http://127.0.0.1:9010",
  access_key_id: "ashcell",
  secret_access_key: "ashcellsecret",
  buckets: %{"us" => "ashcell-test", "eu" => "ashcell-test-eu"}

config :ash_cell,
  repo: Region.CellRepo,
  dir: "priv/cells",
  max_resident: 64

import_config "#{config_env()}.exs"
