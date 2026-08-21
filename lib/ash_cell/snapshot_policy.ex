defmodule AshCell.SnapshotPolicy do
  @moduledoc """
  When a cell should ship itself to the object store, and when it should not.

  ## The gap this closes

  Before this, a cell reached the bucket only when the node drained. A clean
  shutdown was therefore safe and `kill -9` lost *everything written since the cell
  activated* — not one second of writes, the whole session. Calling that an RPO was
  generous.

  Shipping on a schedule turns that into a bounded loss. It is not RPO=0 and does
  not pretend to be: an acknowledged write still lives only on local disk until the
  next shipment, and closing that gap needs the ack itself gated on durability,
  which is a different design (see `docs/spec.md` §2).

  ## Two triggers, because size alone is not enough

  A cell ships when **either** holds:

    * `wal_bytes` — the write-ahead log has grown past this. Proportional to how
      much would be lost, and the cheapest useful signal available: one `File.stat`
      on the `-wal` sidecar, no SQLite involvement. Dirty page count is the truer
      measure and `exqlite` does not expose it.
    * `max_age_ms` — there is *anything* unshipped and it has been that long. Size
      alone would leave a cell with one small write unshipped indefinitely, which is
      exactly the low-traffic tenant whose single write matters most.

  A cell with an empty WAL never ships. That matters more as cells get smaller and
  more numerous: a dormant per-entity cell should cost nothing, and paying a
  whole-file PUT every interval for a cell nobody wrote to is pure waste.

  ## Why the schedule is staggered

  `interval_ms` is how often a cell *asks* the question, not how often it ships. A
  fleet that all asked on the same tick would answer it together, and since
  `AshCell.Replicator` ships whole files, that is the entire fleet's bytes leaving
  at once — the thundering herd the design already worries about on node loss,
  re-created on a timer.

  So each cell takes a random offset into its first interval and re-jitters every
  tick. Two cells that start in the same second drift apart instead of marching in
  lockstep.

  ## Defaults, and why they are on

  On by default whenever the fleet has an object store, because the alternative is
  a durability feature that protects only the people who knew to look for it, and
  the failure it prevents is silent until the node dies. A fleet with no store does
  not ship at all; there is nowhere to ship to.
  """

  @default_wal_bytes 4 * 1024 * 1024
  @default_max_age_ms :timer.seconds(60)
  @default_interval_ms :timer.seconds(5)

  defstruct wal_bytes: @default_wal_bytes,
            max_age_ms: @default_max_age_ms,
            interval_ms: @default_interval_ms,
            enabled?: true

  @type t :: %__MODULE__{}

  @doc """
  Builds a policy from fleet options.

      {AshCell, store: store, snapshot: [wal_bytes: 1_000_000, max_age_ms: 30_000]}

  `snapshot: false` turns it off for a fleet that would rather ship only on drain.
  """
  @spec new(keyword() | false | nil, keyword()) :: t()
  def new(false, _fleet_opts), do: %__MODULE__{enabled?: false}

  def new(opts, fleet_opts) do
    # Nothing to ship to, so nothing to schedule. Not a misconfiguration: a local
    # fleet with no bucket is a supported way to run this.
    if Keyword.get(fleet_opts, :store) do
      opts = opts || []

      %__MODULE__{
        wal_bytes: Keyword.get(opts, :wal_bytes, @default_wal_bytes),
        max_age_ms: Keyword.get(opts, :max_age_ms, @default_max_age_ms),
        interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
        enabled?: true
      }
    else
      %__MODULE__{enabled?: false}
    end
  end

  @doc """
  Whether to ship, given the WAL size and how long it has been since the last
  successful shipment.

  `wal_bytes` of 0 is never shippable whatever the age, so a dormant cell costs
  nothing.
  """
  @spec ship?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def ship?(%__MODULE__{enabled?: false}, _wal_bytes, _age_ms), do: false
  def ship?(_policy, 0, _age_ms), do: false

  def ship?(%__MODULE__{} = policy, wal_bytes, age_ms) do
    wal_bytes >= policy.wal_bytes or age_ms >= policy.max_age_ms
  end

  @doc """
  A delay in `[interval_ms/2, interval_ms*3/2)`, redrawn every tick.

  Jittered rather than fixed so a fleet that starts together does not ship
  together. See the moduledoc.
  """
  @spec next_delay(t()) :: pos_integer()
  def next_delay(%__MODULE__{interval_ms: interval}) do
    half = div(interval, 2)
    max(1, half + :rand.uniform(max(1, interval)))
  end

  @doc """
  A delay into the *first* interval, uniform in `[0, interval_ms)`.

  Separate from `next_delay/1` because the first tick is the one that decides
  whether a fleet activating together is spread out at all.
  """
  @spec initial_delay(t()) :: pos_integer()
  def initial_delay(%__MODULE__{interval_ms: interval}), do: :rand.uniform(max(1, interval))

  @doc "Size of the WAL sidecar beside `path`, or 0 if there is not one."
  @spec wal_bytes(Path.t()) :: non_neg_integer()
  def wal_bytes(path) do
    case File.stat(path <> "-wal") do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
