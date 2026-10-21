import Config

config :logger, level: :warning

# Under the build directory, so a test run leaves nothing in priv/.
config :ash_cell, dir: Path.expand("../_build/test/cells", __DIR__)
config :region, Region.GlobalRepo, database: Path.expand("../_build/test/global.db", __DIR__)
