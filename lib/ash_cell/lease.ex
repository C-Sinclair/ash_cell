defmodule AshCell.Lease do
  @moduledoc """
  Single-writer ownership of a cell, coordinated entirely by the bucket.

  A lease is one object per cell, claimed with a conditional write. Two nodes
  can race and exactly one wins, with no membership protocol, no failure detector,
  no quorum, and no need for the nodes to know that the other exists.

  ## The lease is not what makes it safe

  Leases expire on a clock, clocks drift, and processes pause, so eventually two
  nodes will both believe they hold one. That is unavoidable and it is *fine*,
  because correctness does not rest here.

  Every durability write is also conditional, keyed by generation
  (`AshCell.Replicator`). A fenced writer that has not noticed yet will find its
  generation already taken and fail, before it has told anybody the write
  succeeded. So:

    * the **conditional write** provides correctness
    * the **lease** provides efficiency, by stopping the fleet from fighting over
      the same cell and rehydrating in a loop

  Being wrong about a lease costs a wasted download. It does not cost data. That
  is the opposite of how a consensus system fails, and it is why clock skew is not
  a correctness concern here.

  ## What this does not do

  It fences *writes*, not *reads*. A node that has lost its lease but can still
  reach clients will keep serving reads from its now-stale copy until it notices.
  Whether that is acceptable depends on the application.
  """

  defstruct [:cell_key, :owner, :etag, :expires_at, :generation]

  @default_ttl_ms 30_000

  def key(cell_key), do: "cells/#{AshCell.CellKey.encode(cell_key)}/lease.json"

  @doc """
  Attempts to take ownership of `cell_key`.

  Returns `{:ok, lease}` if this owner now holds it, or `{:error, {:held_by, owner}}`
  if someone else does and their lease has not expired.
  """
  def claim(store, cell_key, owner, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    now = System.system_time(:millisecond)

    case AshCell.ObjectStore.get(store, key(cell_key)) do
      {:error, :not_found} ->
        # Nobody has ever held it. If-None-Match means only one racer can create it.
        write(store, cell_key, owner, now + ttl, 1, if_none_match: true)

      {:ok, body, etag} ->
        held = Jason.decode!(body)

        cond do
          held["owner"] == owner ->
            write(store, cell_key, owner, now + ttl, held["generation"], if_match: etag)

          held["expires_at"] > now ->
            {:error, {:held_by, held["owner"]}}

          true ->
            # Expired. If-Match means only one racer can take it over, and the
            # generation bump fences the previous owner's in-flight writes.
            write(store, cell_key, owner, now + ttl, held["generation"] + 1, if_match: etag)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Extends a lease this owner already holds. Fails if it was taken."
  def renew(store, %__MODULE__{} = lease, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    expires = System.system_time(:millisecond) + ttl

    write(store, lease.cell_key, lease.owner, expires, lease.generation, if_match: lease.etag)
  end

  @doc "Releases a lease so another node can take it without waiting for expiry."
  def release(store, %__MODULE__{} = lease) do
    AshCell.ObjectStore.delete(store, key(lease.cell_key))
  end

  @doc "Who holds this lease right now, if anyone."
  def holder(store, cell_key) do
    case AshCell.ObjectStore.get(store, key(cell_key)) do
      {:ok, body, _etag} ->
        held = Jason.decode!(body)

        if held["expires_at"] > System.system_time(:millisecond) do
          {:ok, held["owner"]}
        else
          {:ok, :expired}
        end

      {:error, :not_found} ->
        {:ok, nil}

      other ->
        other
    end
  end

  defp write(store, cell_key, owner, expires_at, generation, opts) do
    body =
      Jason.encode!(%{owner: owner, expires_at: expires_at, generation: generation})

    case AshCell.ObjectStore.put(store, key(cell_key), body, opts) do
      {:ok, etag} ->
        {:ok,
         %__MODULE__{
           cell_key: cell_key,
           owner: owner,
           etag: etag,
           expires_at: expires_at,
           generation: generation
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
