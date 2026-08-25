defmodule AshCell.Branch do
  @moduledoc """
  Copy-on-write branches over a cell's snapshot history: fork a database at a point
  in its past, write to the copy in isolation, and either fast-forward the origin to
  it or be refused.

  A cell is one file, so "the tenant's database at txid N" is an object in a bucket
  and a branch is a copy of that object under a new cell key. Because the key is
  opaque ([ADR-07](../../docs/decisions/ADR-07-opaque-cell-keys.md)), `"acme"`
  branching to `"acme@pr-1234"` needs no new routing concept — and because the
  branch is a different key, it gets its own file, its own lease, and its own txid
  namespace, so its fencing is correct with no changes.

  ## Merge is fast-forward or refusal, and nothing else

  There is no general merge of two divergent SQLite databases. Two conflicting
  `UPDATE`s on one row have no reconciliation that is not a domain rule, and a
  library that invented one would be silently picking a winner. So merge here is
  the one case that is decidable: if the origin has not been written to since the
  branch point, the branch's file becomes the origin's file. Anything else is
  refused, with both change counters in the error so the caller can see the
  divergence it has to resolve itself. See
  [ADR-23](../../docs/decisions/ADR-23-merge-by-fast-forward-or-refuse.md).

  This is less than it sounds like a limitation. It is what Neon's branches
  actually do — a branch is where a migration or a risky change is *rehearsed*, and
  what gets promoted is the change, not a reconciliation of two histories.

  ## Divergence is measured by change counter, not txid

  The obvious fast-forward test — "has the origin's txid moved" — is wrong, because
  txid counts shipments and shipments are periodic, so an idle origin's txid
  advances while its contents do not. `AshCell.History.change_counter/1` reads
  SQLite's own file change counter instead, which moves only on a write
  transaction. See that module for why it must only be read from a checkpointed
  file.

  ## What this does not do

  It does not authorise anything. Forking a cell produces a full copy of its data
  under a key the caller chose, so who may fork whom is the application's decision,
  and the library will not make it. It also does not persist provenance: `fork/3`
  returns a record and the application stores it, because a fork record kept
  *inside* either cell is a record a fork inherits and then lies about.
  """

  require Logger

  @enforce_keys [:origin, :branch, :from_txid, :requested_txid, :exact?, :digest, :bytes]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc """
  Copies `origin`'s snapshot at `from` to a new cell key, writable and isolated.

  Options:

    * `:to` — the branch's cell key. Required, and must be unused: an existing file
      or any existing snapshot under that key refuses the fork rather than being
      written over.
    * `:from` — a txid, or `:latest` (the default). An inexact txid resolves *down*;
      the record says which txid was actually opened and whether it was exact.

  The returned `t:t/0` is the provenance the application must keep — `merge/3`
  needs its `digest` to decide whether a fast-forward is legal, and nothing in the
  cell remembers it.
  """
  @spec fork(AshCell.ObjectStore.t(), binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def fork(store, origin, opts) do
    branch = Keyword.fetch!(opts, :to)
    from = Keyword.get(opts, :from, :latest)

    with :ok <- refuse_same_key(origin, branch),
         :ok <- refuse_if_used(store, branch),
         {:ok, resolved} <- AshCell.History.resolve(store, origin, from),
         {:ok, bytes, _etag} <-
           AshCell.ObjectStore.get(
             store,
             AshCell.Replicator.snapshot_key(origin, resolved.resolved)
           ),
         {:ok, digest} <- AshCell.History.digest(bytes),
         :ok <- write_database(branch, bytes) do
      {:ok,
       %__MODULE__{
         origin: origin,
         branch: branch,
         from_txid: resolved.resolved,
         requested_txid: resolved.requested,
         exact?: resolved.exact?,
         digest: digest,
         bytes: byte_size(bytes)
       }}
    end
  end

  @doc """
  Fast-forwards `record.origin` to `record.branch`, or refuses.

  Succeeds only if the origin's content digest still matches the one recorded when
  the branch was cut. On success the branch's database becomes the origin's, and the
  result is shipped so the durable history reflects it.

  Refusals, all of them deliberate:

    * `{:error, {:not_fast_forward, details}}` — the origin was written to since the
      branch point. `details` carries `:origin_digest` and `:branch_forked_at`, so
      the caller can see the divergence rather than being told merely that there was
      one. This is the ordinary case for a branch left open while its origin kept
      serving, and it is not an error in the system.
    * `{:error, :not_owner}` — this node does not hold the origin's lease. Writing
      the origin's file from a node that does not own it is exactly what fencing
      exists to prevent.
    * `{:error, :precondition_failed}` — this node was fenced *during* the merge.
      See the caveat below.

  ## The digest is checked twice, on purpose

  Once before closing the origin, to fail fast and cheaply, and again after the
  origin's connection is down — because a write that lands between those two moments
  would otherwise be overwritten by a merge that had already decided it was safe.
  The second check is the load-bearing one; the first only saves the close.

  ## Not atomic across disk and bucket

  The origin's local file is replaced, then shipped. Being fenced in between leaves
  the merge on disk and absent from the bucket, and the cell quarantined by
  `AshCell.Replicator`'s fail-closed path
  ([ADR-10](../../docs/decisions/ADR-10-fail-closed-on-a-refused-shipment.md)) —
  so it stops serving rather than serving a state it cannot persist. That is the
  right failure, but recovering it is an operator restoring the origin from its last
  good snapshot, and the branch is still there to retry from.
  """
  @spec merge(AshCell.ObjectStore.t(), t()) :: {:ok, map()} | {:error, term()}
  def merge(store, %__MODULE__{} = record) do
    %{origin: origin, branch: branch} = record

    with :ok <- refuse_same_key(origin, branch),
         :ok <- require_ownership(store, origin),
         :ok <- require_fast_forward(origin, record),
         {:ok, bytes} <- checkpointed_bytes(branch) do
      # Closing a cell drops the manager's in-memory lease for it, so the lease has
      # to be carried across the close by hand. Without this the merge lands on disk
      # and then ships as `:no_lease` -- a durable no-op, reported as success, which
      # is the exact shape of failure the fencing work exists to prevent. This node
      # still holds the lease *in the bucket*; only the local record went.
      lease = AshCell.Manager.lease(origin)

      # await_repo?: true is load-bearing -- a plain close returns while the origin's
      # SQLite connection is still shutting down, and that connection checkpoints its
      # WAL into the .db on the way out, over the bytes written below.
      AshCell.Manager.close(origin, await_repo?: true)
      if lease, do: :ok = AshCell.Manager.put_lease(origin, lease)

      with :ok <- require_fast_forward(origin, record),
           :ok <- write_database(origin, bytes),
           {:ok, shipped} <- ship(store, origin) do
        {:ok, Map.merge(shipped, %{origin: origin, branch: branch, bytes: byte_size(bytes)})}
      end
    end
  end

  @doc """
  Deletes a branch: its database, its snapshots, and its lease objects.

  Refuses a cell key that is not known to be a branch, because the argument is a
  cell key and a cell key for a branch looks exactly like a cell key for a
  production tenant. Pass the `t:t/0` from `fork/3`, not a string.
  """
  @spec drop(AshCell.ObjectStore.t(), t()) :: {:ok, map()} | {:error, term()}
  def drop(store, %__MODULE__{branch: branch}) do
    {:ok, removed} = AshCell.Manager.delete(branch)

    with {:ok, keys} <-
           AshCell.ObjectStore.list(store, AshCell.Replicator.snapshot_prefix(branch)) do
      for key <- keys, do: AshCell.ObjectStore.delete(store, key)
      AshCell.ObjectStore.delete(store, AshCell.Lease.key(branch))
      AshCell.ObjectStore.delete(store, AshCell.Lease.generation_key(branch))

      {:ok, %{branch: branch, files: removed, snapshots: length(keys)}}
    end
  end

  defp require_fast_forward(origin, %__MODULE__{digest: forked_at}) do
    case current_digest(origin) do
      {:ok, ^forked_at} ->
        :ok

      {:ok, digest} ->
        {:error, {:not_fast_forward, %{origin_digest: digest, branch_forked_at: forked_at}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Digests the origin from a checkpointed file. Checkpointing needs the cell open; a
  # cell that is not resident has nothing unfolded in its WAL, so the file on disk
  # already tells the truth and opening it just to close it would be worse.
  defp current_digest(cell_key) do
    if resident?(cell_key) do
      :ok = AshCell.checkpoint_cell(cell_key)
    end

    AshCell.History.digest_at(AshCell.path_for(cell_key))
  end

  defp checkpointed_bytes(cell_key) do
    if resident?(cell_key) do
      :ok = AshCell.checkpoint_cell(cell_key)
      AshCell.Manager.close(cell_key, await_repo?: true)
    end

    File.read(AshCell.path_for(cell_key))
  end

  defp resident?(cell_key) do
    match?({:ok, _pid}, AshCell.Registry.lookup(cell_key))
  end

  # A fleet with no object store has no leases and nothing to fence, so ownership is
  # vacuous rather than absent. A fleet *with* one and no lease for this cell means
  # this node does not own it, and must not write its file.
  defp require_ownership(nil, _cell_key), do: :ok

  defp require_ownership(_store, cell_key) do
    if AshCell.Manager.lease(cell_key), do: :ok, else: {:error, :not_owner}
  end

  defp ship(store, cell_key) do
    case AshCell.Replicator.ship(store, cell_key) do
      {:ok, :no_lease} -> {:ok, %{txid: nil, shipped?: false}}
      {:ok, %{txid: txid}} -> {:ok, %{txid: txid, shipped?: true}}
      {:ok, :in_flight} -> {:error, :ship_in_flight}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_database(cell_key, bytes) do
    path = AshCell.path_for(cell_key)
    File.mkdir_p!(Path.dirname(path))

    # A stale -wal beside a replaced .db is not merely leftover: SQLite will apply
    # frames belonging to a different database to this one.
    for suffix <- ["-wal", "-shm"], do: File.rm(path <> suffix)

    File.write(path, bytes)
  end

  defp refuse_same_key(key, key), do: {:error, :same_cell}
  defp refuse_same_key(_origin, _branch), do: :ok

  # A fork that lands on a used key is a fork that silently destroys a database, so
  # both halves of "used" are checked: the local file, and the object store, because
  # a cell can be durable here and not yet resident on this node.
  defp refuse_if_used(store, branch) do
    cond do
      File.exists?(AshCell.path_for(branch)) ->
        {:error, {:key_in_use, :local_file}}

      true ->
        case AshCell.ObjectStore.list(store, AshCell.Replicator.snapshot_prefix(branch)) do
          {:ok, []} -> :ok
          {:ok, _keys} -> {:error, {:key_in_use, :snapshots}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
