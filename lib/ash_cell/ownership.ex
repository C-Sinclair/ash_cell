defmodule AshCell.Ownership do
  @moduledoc """
  Read fencing: refusing to serve from a cell this node may no longer own.

  ## The gap this closes

  Conditional writes fence *writes*. A displaced owner discovers it has been
  fenced when its durability write is refused, before it has acknowledged
  anything, so no acknowledged write is ever lost.

  Reads get no such moment. A node partitioned from its peers but still able to
  reach clients keeps answering from a local database that another node has since
  taken over and moved on from. Nothing fails; the answers are simply out of date,
  and plausible. For clinical or financial data, "plausible but stale" is worse
  than an error.

  ## The mechanism, and its cost

  A lease carries an expiry. A holder that has not renewed within its TTL must
  assume it has been displaced and stop serving. `check/2` enforces exactly that,
  which buys bounded staleness — a read is never more than `ttl_ms` behind
  ownership — at the price of an assumption the rest of the design avoids:

  > **This is the one place clock skew matters.** Everything else here is safe
  > under arbitrary clock drift because correctness rests on conditional writes.
  > Bounded staleness cannot be: the bound *is* a duration. A node whose clock
  > runs slow will serve stale reads for longer than it believes.

  Monotonic time is used for the elapsed-time measurement so that a wall-clock
  step (NTP correction, VM migration) cannot silently extend the window. That
  removes the worst case but not the underlying dependency on the TTL being
  honestly enforced.

  ## Three levels, and picking one honestly

    * `:none` — do not check. Correct when stale reads are harmless, and the only
      option with no clock assumption at all.
    * `:bounded` — refuse to serve once the local lease has expired. The usual
      choice.
    * `:strict` — re-read the lease from the object store before serving. No
      staleness window, one round trip per read, and it throws away the entire
      performance argument for this architecture. Reach for it on a specific read
      that genuinely needs it, never as a global default.
  """

  defstruct [:tenant, :owner, :expires_at_monotonic, :generation, :ttl_ms, :lease]

  @doc """
  Records a freshly acquired or renewed lease so reads can be checked against it.

  `expires_at_monotonic` is derived here, from monotonic time, rather than taken
  from the lease's wall-clock expiry.
  """
  def held(%AshCell.Lease{} = lease, ttl_ms) do
    %__MODULE__{
      tenant: lease.tenant,
      owner: lease.owner,
      generation: lease.generation,
      ttl_ms: ttl_ms,
      expires_at_monotonic: System.monotonic_time(:millisecond) + ttl_ms,
      lease: lease
    }
  end

  @doc """
  Decides whether this node may still serve `tenant`.

  Returns `:ok`, or `{:error, {:lease_expired, ms_overdue}}` when the holder is
  past its TTL. The overdue figure is included because "how far past" is the first
  thing you want during an incident.
  """
  def check(ownership, mode \\ :bounded)

  def check(_ownership, :none), do: :ok

  def check(nil, _mode), do: {:error, :no_lease}

  def check(%__MODULE__{} = ownership, :bounded) do
    overdue = System.monotonic_time(:millisecond) - ownership.expires_at_monotonic

    if overdue > 0 do
      {:error, {:lease_expired, overdue}}
    else
      :ok
    end
  end

  def check(%__MODULE__{} = ownership, {:strict, store}) do
    case AshCell.Lease.holder(store, ownership.tenant) do
      {:ok, owner} when owner == ownership.owner -> :ok
      {:ok, other} -> {:error, {:not_owner, other}}
      other -> other
    end
  end

  @doc """
  Runs `fun` only if this node still holds `tenant`.

  The read path's counterpart to the conditional write on the write path: it
  cannot make a stale read impossible, only bounded.
  """
  def with_ownership(ownership, mode \\ :bounded, fun) when is_function(fun, 0) do
    case check(ownership, mode) do
      :ok -> {:ok, fun.()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Milliseconds until this lease must be renewed."
  def remaining_ms(%__MODULE__{} = ownership) do
    max(ownership.expires_at_monotonic - System.monotonic_time(:millisecond), 0)
  end

  @doc """
  Whether renewal should happen now.

  Renew at a third of the TTL rather than at expiry, so a single slow or dropped
  renewal does not immediately stop the node serving reads.
  """
  def renew_due?(%__MODULE__{} = ownership) do
    remaining_ms(ownership) < div(ownership.ttl_ms, 3)
  end
end
