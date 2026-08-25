defmodule Branch.Service do
  @moduledoc """
  The control plane: provision a database, branch it, run SQL against a branch,
  promote a branch back, throw one away.

  Everything here is a thin arrangement of `AshCell.Branch` and `Branch.Catalog`.
  The interesting logic is in the library; what this module contributes is the two
  things a library cannot decide — who owns which cell, and where provenance lives.

  ## Every branch takes a lease

  A cell can only ship if this node holds its lease, and branching is entirely
  about shipping: a branch is cut from a snapshot and a merge ends in one. So
  `adopt/1` claims a lease the first time a cell is touched. In a single-node demo
  that always succeeds; the point of doing it properly is that the refusal path is
  real code rather than an assumption, and a second node running this demo against
  the same bucket would be fenced rather than corrupting anything.
  """

  require Logger

  alias Branch.{Catalog, Cells}

  @lease_ttl_ms 60_000

  @doc """
  Creates a database and its root branch, and ships it once so it has a history.

  The shipment is not incidental. A branch is cut from a snapshot, so a database
  that has never shipped cannot be branched — provisioning without shipping would
  produce a database whose first branch attempt fails for a reason the user cannot
  see.
  """
  def provision(database, root \\ "main") do
    key = Cells.key(database, root)

    with {:ok, _} <- Catalog.create_database(database),
         {:ok, _} <- adopt(key),
         {:ok, _} <- ship(key),
         {:ok, _} <-
           Catalog.record_branch(%{
             id: key,
             database: database,
             name: root,
             parent: nil,
             from_txid: nil,
             digest: nil
           }) do
      {:ok, %{database: database, branch: root, cell: key}}
    end
  end

  @doc """
  Cuts `name` from `parent` at a point in the parent's history.

  `from` is a txid or `:latest`. An inexact txid resolves *down* to the newest
  snapshot at or before it, and the result says which txid was actually used — a
  branch that silently lands somewhere other than where it was asked for is worse
  than one that says so.
  """
  def create_branch(database, parent, name, from \\ :latest) do
    origin = Cells.key(database, parent)
    key = Cells.key(database, name)

    with :ok <- refuse_existing(database, name),
         {:ok, _} <- adopt(origin),
         # Cut from a point that includes everything written so far, rather than
         # from whatever the periodic policy last happened to ship.
         {:ok, _} <- ship_if_dirty(origin),
         {:ok, record} <- AshCell.Branch.fork(Cells.store(), origin, to: key, from: from),
         {:ok, _} <- adopt(key),
         {:ok, _} <-
           Catalog.record_branch(%{
             id: key,
             database: database,
             name: name,
             parent: parent,
             from_txid: record.from_txid,
             digest: record.digest
           }) do
      {:ok, record}
    end
  end

  @doc """
  Fast-forwards a branch's parent to it, or refuses.

  See [ADR-23](../../../docs/decisions/ADR-23-merge-by-fast-forward-or-refuse.md).
  The refusal is the interesting outcome and is passed through untouched, digests
  and all, because a caller told only "conflict" cannot do anything about it.
  """
  def merge(database, name) do
    with {:ok, row} <- fetch_branch(database, name),
         {:ok, record} <- Catalog.to_record(row),
         {:ok, _} <- adopt(record.origin),
         # The branch's own writes have to be in its file, not its WAL, before the
         # file is copied over the origin.
         {:ok, _} <- ship_if_dirty(record.branch),
         {:ok, result} <- AshCell.Branch.merge(Cells.store(), record),
         {:ok, _} <- Catalog.mark_merged(row) do
      {:ok, result}
    end
  end

  @doc "Deletes a branch's database, snapshots, lease, and catalog row."
  def drop_branch(database, name) do
    with {:ok, row} <- fetch_branch(database, name),
         {:ok, record} <- Catalog.to_record(row),
         {:ok, dropped} <- AshCell.Branch.drop(Cells.store(), record),
         {:ok, _} <- Catalog.delete_branch(row) do
      {:ok, dropped}
    end
  end

  @doc """
  Runs one SQL statement against a branch, and returns columns and rows.

  Deliberately raw. The subject of this demo is the database file, not the resource
  layer, and a SQL console is the shortest way to let somebody write to a branch and
  see for themselves that the origin did not change.
  """
  def query(database, name, sql) do
    key = Cells.key(database, name)

    with {:ok, pid} <- AshCell.Manager.ensure_started(key) do
      case Ecto.Adapters.SQL.query(AshCell.Cell.repo_pid(pid), sql, []) do
        {:ok, result} ->
          {:ok, %{columns: result.columns || [], rows: result.rows || [], count: result.num_rows}}

        {:error, %{message: message}} ->
          {:error, message}

        {:error, other} ->
          {:error, inspect(other)}
      end
    end
  end

  @doc "The snapshot history of a branch, newest first."
  def history(database, name) do
    with {:ok, snapshots} <- AshCell.History.list(Cells.store(), Cells.key(database, name)) do
      {:ok, Enum.reverse(snapshots)}
    end
  end

  @doc "Ships a branch now, so it has a point somebody can branch from."
  def snapshot(database, name), do: ship(Cells.key(database, name))

  @doc """
  Claims the lease for a cell if this node does not already hold one.

  Idempotent, because every entry point calls it and a lease that is already held
  must not be re-claimed — a fresh claim takes a new generation, and the high-water
  mark is deliberately read only once per adoption
  ([ADR-08](../../../docs/decisions/ADR-08-fence-by-shared-txid.md)).
  """
  def adopt(cell_key) do
    case AshCell.Manager.lease(cell_key) do
      nil ->
        with {:ok, lease} <-
               AshCell.Lease.claim(Cells.store(), cell_key, to_string(node()),
                 ttl_ms: @lease_ttl_ms
               ) do
          :ok = AshCell.Manager.put_lease(cell_key, lease)
          {:ok, lease}
        end

      lease ->
        {:ok, lease}
    end
  end

  defp ship(cell_key) do
    case AshCell.Replicator.ship(Cells.store(), cell_key) do
      {:ok, :no_lease} -> {:error, :no_lease}
      {:ok, :in_flight} -> {:error, :ship_in_flight}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # A shipment whose only outcome would be a duplicate of the newest snapshot is
  # skipped, so branching twice in a row does not fill the bucket with identical
  # files. "Dirty" is the same content digest the fast-forward test uses.
  defp ship_if_dirty(cell_key) do
    store = Cells.store()

    with {:ok, _} <- adopt(cell_key),
         :ok <- AshCell.checkpoint_cell(cell_key),
         {:ok, digest} <- AshCell.History.digest_at(AshCell.path_for(cell_key)) do
      case newest_digest(store, cell_key) do
        {:ok, ^digest} -> {:ok, :unchanged}
        _ -> ship(cell_key)
      end
    end
  end

  defp newest_digest(store, cell_key) do
    with {:ok, txid} <- AshCell.Replicator.newest_snapshot(store, cell_key),
         {:ok, bytes, _etag} <-
           AshCell.ObjectStore.get(store, AshCell.Replicator.snapshot_key(cell_key, txid)) do
      AshCell.History.digest(bytes)
    end
  end

  defp fetch_branch(database, name) do
    case Catalog.branch(database, name) do
      nil -> {:error, :no_such_branch}
      row -> {:ok, row}
    end
  end

  defp refuse_existing(database, name) do
    if Catalog.branch(database, name), do: {:error, :branch_exists}, else: :ok
  end
end
