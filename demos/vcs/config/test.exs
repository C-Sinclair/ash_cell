import Config

config :vcs, :cell_dir, "priv/test_cells"
config :vcs, VcsWeb.Endpoint, http: [ip: {127, 0, 0, 1}, port: 4002], server: false
config :logger, level: :warning

# The snapshotter is started by the application, so tests drive it with `Snapshotter.sweep/1`
# rather than a timer. An hour keeps a background sweep from firing mid-assertion.
config :vcs, :snapshot_interval_ms, :timer.hours(1)

# Replication tests run against a real MinIO. They are tagged `:minio` and excluded by
# default, because a mock of conditional-write semantics would only confirm our own
# understanding of them.
config :vcs, :object_store,
  endpoint: System.get_env("VCS_S3_ENDPOINT", "http://127.0.0.1:9010"),
  bucket: System.get_env("VCS_S3_BUCKET", "ashcell-test"),
  access_key_id: System.get_env("VCS_S3_ACCESS_KEY_ID", "ashcell"),
  secret_access_key: System.get_env("VCS_S3_SECRET_ACCESS_KEY", "ashcellsecret")
