defmodule AshCell.History do
  @moduledoc """
  The read side of a cell's snapshot history, and the one number that says whether
  a database has been written to.

  `AshCell.Replicator` writes snapshots keyed by txid and never mutates one, so the
  object-store prefix for a cell *is* a timeline. This module reads it, and answers
  the two questions branching needs: what points exist, and which one does a
  requested txid land on.

  ## Reads land on snapshot boundaries

  Snapshots are periodic ([ADR-12](../../docs/decisions/ADR-12-whole-file-snapshots-on-a-schedule.md)),
  so history is not continuous. `resolve/3` therefore resolves a requested txid
  **down** to the newest snapshot at or before it, and says so: the return value
  carries both the txid asked for and the txid available, plus `exact?`. A caller
  that needs exactness compares them rather than trusting the answer.

  Refusing an inexact txid was the alternative and it is more honest in the small,
  but it makes the common case ("give me roughly yesterday") unusable, and a caller
  who does not check `exact?` is no worse off than one who did not handle the error.

  ## Divergence is a content digest, and it is not the txid

  Branching needs to know whether a database has been written to since a point.

  The txid cannot answer that: it counts *shipments*, and the snapshot policy ships
  on a schedule, so an idle cell's txid advances while its contents do not. A
  fast-forward test built on txid refuses merges that have no conflict.

  SQLite's file change counter (bytes 24..27 of the header) looked like the right
  number and is not, in this configuration. It is documented as incrementing on every
  write transaction, but that is rollback-journal behaviour: **in WAL mode it does not
  move per transaction**, because WAL uses the WAL-index and its salts for the cache
  invalidation the counter exists to drive. Measured, because it was believed and then
  acted on: three consecutive inserts, each followed by a `wal_checkpoint(TRUNCATE)`,
  left the counter at 2 throughout. A fast-forward test built on it therefore reports
  "no divergence" for a database that has been rewritten, and merge silently discards
  the origin's writes. `test/branch_test.exs` covers this directly.

  So divergence is a **SHA-256 of the checkpointed database file**. It is O(size), which
  sounds worse than it is: `AshCell.Replicator` already reads and PUTs the whole file on
  every shipment, so hashing adds a pass over bytes that are being read anyway, and cells
  are small by design. Measured stable across repeated checkpoints with no writes between
  them, and different after every write — which is the property the test needs and the
  counter did not have.

  The one subtlety is WAL again: a commit lands in `-wal` and is not in the `.db` until a
  checkpoint folds it in, so a digest taken over an unfolded database under-reports. Every
  digest here is therefore taken over a *checkpointed* artefact — a snapshot in the bucket
  (`AshCell.Replicator.snapshot/3` checkpoints first) or a file this node has just
  checkpointed. `digest/1` takes bytes and `digest_at/1` takes a path; neither takes a
  running cell, so there is no call shape that reads an unfolded one.
  """

  # The size of a SQLite database header: anything shorter is not a database.
  @header_size 100

  @doc """
  The snapshot timeline for `cell_key`, oldest first.

  Each entry is `%{txid:, bytes:, shipped_at:}`. `shipped_at` is the object store's
  clock and is a label, not an ordering — the txid orders snapshots.
  """
  @spec list(AshCell.ObjectStore.t(), binary()) :: {:ok, [map()]} | {:error, term()}
  def list(store, cell_key) do
    prefix = AshCell.Replicator.snapshot_prefix(cell_key)

    with {:ok, entries} <- AshCell.ObjectStore.list_details(store, prefix) do
      {:ok,
       entries
       |> Enum.map(fn entry ->
         %{txid: txid_of(entry.key), bytes: entry.bytes, shipped_at: entry.modified_at}
       end)
       |> Enum.sort_by(& &1.txid)}
    end
  end

  @doc """
  Resolves a requested txid to the snapshot that actually holds it.

  `:latest` picks the newest. An integer resolves **down** to the newest snapshot at
  or before it. Returns `%{requested:, resolved:, exact?:}`, or
  `{:error, :not_found}` for a cell that has never shipped, and
  `{:error, {:no_snapshot_at_or_before, txid}}` when the request predates the oldest
  snapshot retained — which is a real state once bucket lifecycle rules start
  expiring history, and is not the same thing as a cell with no history at all.
  """
  @spec resolve(AshCell.ObjectStore.t(), binary(), :latest | pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def resolve(store, cell_key, requested \\ :latest) do
    with {:ok, snapshots} <- list(store, cell_key) do
      case {snapshots, requested} do
        {[], _} ->
          {:error, :not_found}

        {snapshots, :latest} ->
          txid = snapshots |> List.last() |> Map.fetch!(:txid)
          {:ok, %{requested: :latest, resolved: txid, exact?: true}}

        {snapshots, requested} when is_integer(requested) ->
          snapshots
          |> Enum.filter(&(&1.txid <= requested))
          |> List.last()
          |> case do
            nil ->
              {:error, {:no_snapshot_at_or_before, requested}}

            %{txid: txid} ->
              {:ok, %{requested: requested, resolved: txid, exact?: txid == requested}}
          end
      end
    end
  end

  @doc """
  A content digest of a database, from its bytes.

  Equal digests over a shared origin mean no writes have happened since. See the
  module doc for why this is a hash and not SQLite's change counter, and why it must
  only ever be taken over a checkpointed artefact.

  Returns `{:error, :not_a_database}` for anything too short to hold a SQLite header,
  which includes the zero-byte file a created-but-never-written cell leaves behind —
  hashing that would give a stable, meaningless answer.
  """
  @spec digest(binary()) :: {:ok, binary()} | {:error, term()}
  def digest(bytes) when is_binary(bytes) and byte_size(bytes) >= @header_size do
    {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  def digest(bytes) when is_binary(bytes), do: {:error, :not_a_database}

  @doc "The digest of the database at `path`, streamed rather than read whole."
  @spec digest_at(Path.t()) :: {:ok, binary()} | {:error, term()}
  def digest_at(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size < @header_size ->
        {:error, :not_a_database}

      {:ok, _} ->
        {:ok,
         path
         |> File.stream!([], 1_048_576)
         |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
         |> :crypto.hash_final()
         |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp txid_of(key), do: key |> Path.basename(".db") |> String.to_integer()
end
