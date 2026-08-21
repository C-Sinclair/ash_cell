# import_deps is load-bearing, not decoration. Without it the formatter does not
# know that Ash and Spark DSL entries are macros taking no parens, and rewrites
# `table "notes"` to `table("notes")` across every resource -- against the
# convention every Ash codebase uses. An incomplete formatter config is why
# `mix format` had never been run here.
[
  import_deps: [:ash, :ash_sqlite, :ecto, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
