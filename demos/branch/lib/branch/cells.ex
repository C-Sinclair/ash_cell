defmodule Branch.Cells do
  @moduledoc """
  The fleet, and the cell key scheme that makes branching a naming convention.

  A cell key here is `"db:<database>@<branch>"`. Nothing in AshCell parses it —
  the key is opaque ([ADR-07](../../../docs/decisions/ADR-07-opaque-cell-keys.md))
  and `AshCell.CellKey.encode/1` is injective, so `@` and `:` survive the trip to a
  filename without two databases colliding on one file. That is the whole reason
  branching needs no new routing concept: a branch is a different key, so it is a
  different file, a different lease, and a different txid namespace.

  This fleet **requires an object store**. Unlike the other demos it cannot degrade
  to local-only, because a branch is a copy of a snapshot and snapshots live in the
  bucket. See the README for MinIO.
  """

  @doc "The cell key for a branch of a database."
  def key(database, branch), do: "db:#{database}@#{branch}"

  @doc "The `{database, branch}` a cell key names. Only the control plane needs this."
  def parse("db:" <> rest) do
    case String.split(rest, "@", parts: 2) do
      [database, branch] -> {:ok, database, branch}
      _ -> :error
    end
  end

  def parse(_), do: :error

  def config do
    [
      repo: Branch.CellRepo,
      dir: Application.get_env(:ash_cell, :dir, "priv/cells"),
      migrator: Branch.Schema,
      store: store(),
      owner: to_string(node()),
      max_resident: 64,
      # Frequent, because the demo's whole subject is the snapshot history and a
      # branch can only be cut from a point that has actually shipped. A production
      # fleet would not ship this often.
      snapshot: [every_ms: 5_000, min_interval_ms: 1_000]
    ]
  end

  def store do
    config = Application.get_env(:branch, :object_store, [])

    AshCell.ObjectStore.new(
      endpoint: config[:endpoint] || "http://127.0.0.1:9010",
      bucket: config[:bucket] || "ashcell-branch",
      access_key_id: config[:access_key_id] || "ashcell",
      secret_access_key: config[:secret_access_key] || "ashcellsecret"
    )
  end
end
