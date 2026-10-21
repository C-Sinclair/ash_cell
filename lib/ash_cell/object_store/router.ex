defmodule AshCell.ObjectStore.Router do
  @moduledoc """
  Chooses the object store a cell's snapshots and lease live in, from its cell key.

  Pass a module implementing this behaviour as the fleet's `store:` option in place of a
  single `AshCell.ObjectStore`, to keep different cells in different buckets — one per
  region, say. `store_for/1` must be a pure function of the key, and must raise for a key
  it cannot place rather than fall back to a default bucket.
  """

  @callback store_for(cell_key :: binary()) :: AshCell.ObjectStore.t()

  @doc "The store for `cell_key` under a fleet's `store:` option: `nil`, a store, or a router."
  @spec resolve(nil | AshCell.ObjectStore.t() | module(), binary()) ::
          AshCell.ObjectStore.t() | nil
  def resolve(nil, _cell_key), do: nil
  def resolve(%AshCell.ObjectStore{} = store, _cell_key), do: store
  def resolve(router, cell_key) when is_atom(router), do: router.store_for(cell_key)
end
