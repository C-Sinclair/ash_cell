defmodule AshCell.Resource.Changes.CarryTenant do
  @moduledoc """
  Copies the changeset's tenant into `context[:data_layer]`.

  This exists for one callback. `Ash.DataLayer.transaction/5` runs *above* the
  data layer — it has to, because a transaction spans every statement an action
  issues — and the only part of the changeset Ash forwards to it is
  `context[:data_layer]`. Nothing else in the transaction reason names a tenant:
  a create carries `resource` and `action`, an update adds `record` and `actor`.

  So without this, `AshSqlite.DataLayer.transaction/4` cannot know which cell to
  open a `BEGIN` against, and a database-per-tenant layout has no default worth
  guessing. Every other callback gets the tenant from the changeset or the query
  directly and needs nothing from here.

  ## Why this does not bring back the old global change

  An earlier version of this extension used a global change to install
  `around_transaction` hooks, and paid for it with `require_atomic? false` on
  every update: Ash calls `c:Ash.Resource.Change.atomic/3` instead of
  `c:Ash.Resource.Change.change/3` when it can build one statement, and a change
  that only implements `change/3` forces the action off the atomic path.

  This one implements both. `atomic/3` returns the changeset untouched, so atomic
  actions stay atomic — and they need nothing from this change anyway, because a
  single statement is already atomic and
  `c:Ash.DataLayer.prefer_transaction_for_atomic_updates?/1` is false, so no
  transaction is opened for them.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.set_context(changeset, %{data_layer: %{tenant: changeset.tenant}})
  end

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, changeset}
end
