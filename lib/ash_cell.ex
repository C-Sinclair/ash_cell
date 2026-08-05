defmodule AshCell do
  @moduledoc """
  Database-per-tenant SQLite for Ash.

  Each tenant is a *cell*: one encrypted SQLite file, owned by exactly one
  process at a time, with compute routed to the data rather than the reverse.

  The mechanism is deliberately small. Ash's `AshSql.dynamic_repo/3` consults
  `query.__ash_bindings__.context.data_layer.repo` before falling back to the
  repo declared in the DSL, so binding a tenant to its own database is a matter
  of putting that tenant's repo pid into the query context. The override travels
  with the query struct rather than the process dictionary, which is why this
  works across `Ash.load` fan-out, `Task.async`, and background jobs where
  `Ecto.Repo.put_dynamic_repo/1` would silently unbind.

  See `docs/spec.md` for the design, the verified constraint list, and the
  staging plan.
  """
end
