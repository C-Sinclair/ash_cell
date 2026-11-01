defmodule AshCell.Lease do
  @moduledoc """
  Single-writer ownership of a cell, coordinated entirely by the bucket.

  A lease is one object per cell, claimed with a conditional write. Two nodes
  can race and exactly one wins, with no membership protocol, no failure detector,
  no quorum, and no need for the nodes to know that the other exists.

  Two other objects sit beside it. The **generation counter** outlives the lease,
  because a lease can be deleted (`release/2` used to, and `AshCell.Branch` still
  does) and a counter derived from the lease body restarted at 1 on every clean handoff — handing two successive owners the same
  generation. A generation that repeats is a fence that does not fence. The
  **txid** a claim records is the durability high-water mark, read once here so
  that nothing on the write path has to read it again; see `AshCell.Replicator`
  for why reading it again would undo the fence.

  ## The lease is not what makes it safe

  Leases expire on a clock, clocks drift, and processes pause, so eventually two
  nodes will both believe they hold one. That is unavoidable and it is *fine*,
  because correctness does not rest here.

  Every durability write is also conditional, keyed by **txid**
  (`AshCell.Replicator`). A fenced writer that has not noticed yet will find its
  next txid already taken and fail, before it has told anybody the write
  succeeded. So:

    * the **conditional write** provides correctness
    * the **lease** provides efficiency, by stopping the fleet from fighting over
      the same cell and rehydrating in a loop

  Being wrong about a lease costs a wasted download. It does not cost data. That
  is the opposite of how a consensus system fails, and it is why clock skew is not
  a correctness concern here.

  It does cost the displaced owner's commits since its last shipment, which were
  acknowledged locally and are refused at the next one. A writer whose clock lags
  its readers by more than the renewal margin pays that on every request another
  node serves; `docs/spec.md` section 8 records it as an open question.

  This paragraph was false for as long as durability was keyed by generation, and
  it is worth saying why rather than quietly fixing it. Successive owners never
  share a generation, so their conditional writes addressed different keys and
  never contended: the fenced writer's write succeeded, it acknowledged, and the
  data was superseded. The claim only holds against a namespace every owner
  shares. `test/fencing_test.exs` holds both halves — that txid collides, and that
  generation would not.

  ## What this does not do

  It fences *writes*, not *reads*. A node that has lost its lease but can still
  reach clients will keep serving reads from its now-stale copy until it notices.
  Whether that is acceptable depends on the application.
  """

  # `renewed?` is true when `claim/4` found this owner already holding the lease.
  # It is not stored in the object; it says which branch of `claim/4` ran. Nor is
  # `ttl_ms`, which `AshCell.LeaseRenewer` renews with.
  defstruct [
    :cell_key,
    :owner,
    :etag,
    :expires_at,
    :generation,
    :txid,
    :ttl_ms,
    renewed?: false
  ]

  @default_ttl_ms 30_000

  @doc "The TTL a claim or renewal asks for when given no `:ttl_ms`."
  def default_ttl_ms, do: @default_ttl_ms

  def key(cell_key), do: "cells/#{AshCell.CellKey.encode(cell_key)}/lease.json"

  @doc """
  Where a cell's generation counter lives.

  Separate from the lease, and never deleted, because a lease can be deleted.
  Deriving the next generation from the lease body meant a clean handoff
  found no lease, started again at 1, and handed two successive owners the same
  generation -- a generation that repeats is a fence that does not fence.
  """
  def generation_key(cell_key),
    do: "cells/#{AshCell.CellKey.encode(cell_key)}/generation"

  @doc """
  Attempts to take ownership of `cell_key`.

  Returns `{:ok, lease}` if this owner now holds it, or `{:error, {:held_by, owner}}`
  if someone else does and their lease has not expired. The lease's `renewed?` is
  true when this owner already held it, and false when it was taken from nobody or
  from an expired owner.
  """
  def claim(store, cell_key, owner, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now = System.system_time(:millisecond)

    store
    |> AshCell.ObjectStore.get(key(cell_key))
    |> case do
      {:error, :not_found} ->
        # Nobody holds it. If-None-Match means only one racer can create it.
        take(store, cell_key, owner, now + ttl, if_none_match: true)

      {:ok, body, etag} ->
        held = Jason.decode!(body)

        cond do
          held["owner"] == owner ->
            # A renewal keeps its generation. Its txid comes from the store, because
            # shipping never rewrites the lease body: the body's txid is the one from
            # the original claim, and adopting it reuses txids this owner already
            # wrote. Reading the mark here does not undo the fence (ADR-08), since the
            # If-Match below fails if anybody else has held the lease since.
            with {:ok, txid} <- AshCell.Replicator.latest_txid(store, cell_key),
                 {:ok, lease} <-
                   write(store, cell_key, owner, now + ttl, held["generation"], txid,
                     if_match: etag
                   ) do
              {:ok, %{lease | renewed?: true}}
            end

          held["expires_at"] > now ->
            {:error, {:held_by, held["owner"]}}

          true ->
            # Expired. If-Match means only one racer can take it over.
            take(store, cell_key, owner, now + ttl, if_match: etag)
        end

      {:error, reason} ->
        {:error, reason}
    end
    |> with_ttl(ttl)
  end

  # Taking a cell from somebody else -- or from nobody -- means allocating a fresh
  # generation and learning where the durability log has got to.
  #
  # Both reads happen before the conditional lease write, so two racers may read
  # the same values; only the winner's are ever used, and the winner is decided by
  # the conditional write. The counter is bumped after winning.
  defp take(store, cell_key, owner, expires_at, opts) do
    # Both reads must succeed before the lease is written. A claim that cannot
    # learn where the durability log has got to must not be granted: the alternative
    # is a new owner that starts reclaiming txids its predecessors already used.
    with {:ok, generation} <- next_generation(store, cell_key),
         {:ok, txid} <- AshCell.Replicator.latest_txid(store, cell_key),
         {:ok, lease} <- write(store, cell_key, owner, expires_at, generation, txid, opts) do
      AshCell.ObjectStore.put(store, generation_key(cell_key), Integer.to_string(generation))
      {:ok, lease}
    end
  end

  # Allocated from a counter that outlives the lease, so it is monotonic across
  # ownership changes even when nobody wrote in between.
  defp next_generation(store, cell_key) do
    case AshCell.ObjectStore.get(store, generation_key(cell_key)) do
      {:ok, body, _etag} -> {:ok, String.to_integer(String.trim(body)) + 1}
      # No counter yet is the first claim, not a failure.
      {:error, :not_found} -> {:ok, 1}
      # Anything else must not be read as "start again at 1", which would hand a
      # generation back out and unfence whoever still holds it.
      other -> other
    end
  end

  @doc "Extends a lease this owner already holds. Fails if it was taken."
  def renew(store, %__MODULE__{} = lease, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    expires = System.system_time(:millisecond) + ttl

    store
    |> write(lease.cell_key, lease.owner, expires, lease.generation, lease.txid,
      if_match: lease.etag
    )
    |> with_ttl(ttl)
  end

  defp with_ttl({:ok, lease}, ttl), do: {:ok, %{lease | ttl_ms: ttl}}
  defp with_ttl(other, _ttl), do: other

  @doc """
  Releases a lease so another node can take it without waiting for expiry.

  Returns `{:error, :precondition_failed}` when the lease has changed since
  `lease` was read, which means another owner holds it and it was left alone.
  """
  def release(store, %__MODULE__{} = lease) do
    # A conditional PUT of an expired lease with no owner, not a DELETE: MinIO
    # ignores If-Match on DELETE (ADR-32), and an unconditional delete let a
    # displaced owner remove its successor's lease.
    body =
      Jason.encode!(%{
        owner: nil,
        expires_at: 0,
        generation: lease.generation,
        txid: lease.txid
      })

    case AshCell.ObjectStore.put(store, key(lease.cell_key), body, if_match: lease.etag) do
      {:ok, _etag} -> :ok
      other -> other
    end
  end

  @doc "Who holds this lease right now, if anyone."
  def holder(store, cell_key) do
    case AshCell.ObjectStore.get(store, key(cell_key)) do
      {:ok, body, _etag} ->
        held = Jason.decode!(body)

        cond do
          is_nil(held["owner"]) -> {:ok, nil}
          held["expires_at"] > System.system_time(:millisecond) -> {:ok, held["owner"]}
          true -> {:ok, :expired}
        end

      {:error, :not_found} ->
        {:ok, nil}

      other ->
        other
    end
  end

  defp write(store, cell_key, owner, expires_at, generation, txid, opts) do
    body =
      Jason.encode!(%{owner: owner, expires_at: expires_at, generation: generation, txid: txid})

    case AshCell.ObjectStore.put(store, key(cell_key), body, opts) do
      {:ok, etag} ->
        {:ok,
         %__MODULE__{
           cell_key: cell_key,
           owner: owner,
           etag: etag,
           expires_at: expires_at,
           generation: generation,
           txid: txid
         }}

      {:error, :precondition_failed} ->
        # Lost the race. Report who won rather than the raw failure.
        case holder(store, cell_key) do
          {:ok, other} when is_binary(other) -> {:error, {:held_by, other}}
          _ -> {:error, :precondition_failed}
        end

      other ->
        other
    end
  end
end
