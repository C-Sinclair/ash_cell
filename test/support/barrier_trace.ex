defmodule AshCell.BarrierTrace do
  @moduledoc """
  Reads the syscall trace produced by `test/fault/barrier_shim.c` and decides,
  per acknowledged commit, whether a durability barrier was requested before the
  acknowledgement.

  This is ADR-20 tier 1's judgement, kept out of the probe script so it can be
  tested on its own against synthetic traces — including on macOS, which cannot
  run the probe at all (SIP strips `DYLD_INSERT_LIBRARIES` before the BEAM
  starts). `test/barrier_trace_test.exs` covers it.

  ## The invariant

  A trace is a list of records in the order the process issued them, and `MARK`
  records are planted by the workload immediately after a write returns to
  Elixir. So each acknowledged commit owns the window of records between the
  previous `MARK` and its own, and the claim under test is:

  > if the window wrote to the `-wal`, then a barrier on the `-wal` was requested
  > after the last of those writes and before the `MARK`.

  Two deliberate looseness decisions, because the alternative is false failures:

    * **A window with no WAL write is durable by definition.** One Ash action is
      several statements and not all of them dirty the log.
    * **`fsync` and `fdatasync` are one thing.** SQLite's unix VFS chooses between
      them by build flags and by the `fullfsync` pragma, and the invariant does
      not care which — only that a barrier was requested and returned.

  What a pass does *not* mean is that the bytes reached the platter. This sees
  what the process asked the kernel for; a lying drive or a reordering filesystem
  is below the syscall boundary. That needs the block layer.
  """

  defstruct [:label, :wal_writes, :wal_syncs, :durable?]

  @type record :: %{op: String.t(), path: String.t()}
  @type t :: %__MODULE__{}

  @doc "Parses the shim's tab-separated trace. Unparseable lines are dropped."
  @spec parse(String.t()) :: [record()]
  def parse(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t") do
        [op, path, _off, _len] -> [%{op: op, path: path}]
        _ -> []
      end
    end)
  end

  @doc """
  One verdict per acknowledged commit, in order.

  Records before the first `MARK` are cell activation and migration, not a commit
  under test, so they are dropped rather than attributed to anything.
  """
  @spec verdicts([record()]) :: [t()]
  def verdicts(trace) do
    trace
    |> split_into_windows()
    |> Enum.map(&verdict/1)
  end

  # Walks the trace once, accumulating records until a MARK closes a window and
  # names it. Written as a fold rather than `chunk_by/2` because the label lives
  # in the delimiter: chunking discards which MARK ended which window, and pairing
  # the two back up afterwards is where an off-by-one silently mislabels every
  # verdict.
  defp split_into_windows(trace) do
    {windows, _pending} =
      Enum.reduce(trace, {[], []}, fn
        %{op: "MARK", path: label}, {windows, pending} ->
          {[{label, Enum.reverse(pending)} | windows], []}

        record, {windows, pending} ->
          {windows, [record | pending]}
      end)

    windows
    |> Enum.reverse()
    # The first MARK closes the activation window, which owns no commit.
    |> Enum.drop(1)
  end

  defp verdict({label, window}) do
    indexed = Enum.with_index(window)

    writes = for {%{op: "write", path: p}, i} <- indexed, wal?(p), do: i
    syncs = for {%{op: "SYNC", path: p}, i} <- indexed, wal?(p), do: i

    %__MODULE__{
      label: label,
      wal_writes: length(writes),
      wal_syncs: length(syncs),
      durable?: durable?(writes, syncs)
    }
  end

  defp durable?([], _syncs), do: true
  defp durable?(_writes, []), do: false
  defp durable?(writes, syncs), do: Enum.max(syncs) > Enum.max(writes)

  defp wal?(path), do: String.ends_with?(path, "-wal")

  @doc "The verdicts that record an acknowledgement made before any barrier."
  @spec violations([t()]) :: [t()]
  def violations(verdicts), do: Enum.reject(verdicts, & &1.durable?)
end
