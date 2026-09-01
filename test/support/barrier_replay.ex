defmodule AshCell.BarrierReplay do
  @moduledoc """
  Reconstructs a cell's files as they would have been on disk had the machine
  lost power at an arbitrary point in the write stream.

  This is ADR-20 tier 2. Tier 1 (`AshCell.BarrierTrace`) asks whether a barrier
  was *requested* before an acknowledgement; it never checks that the resulting
  bytes are a database anyone can open. That is what this does: replay the traced
  writes up to a cut, hand the result to SQLite, and see.

  ## The crash model

  Every write is applied in the order the process issued it, and the cut is a
  prefix. That models a machine that stopped, losing everything not yet written,
  and it is the same model `dm-log-writes`' `replay-log` uses.

  It is deliberately *weaker* than a real power failure in one respect and the
  probe says so rather than papering over it: a real device may reorder writes
  between barriers, so some reachable on-disk states are not prefixes of the
  issue order. Catching those needs the block layer (tier 3). A prefix replay
  finds the bugs where a barrier is missing or in the wrong place, which is the
  class this ADR is about, and it finds them without root.

  ## Why the files start empty

  The workload deletes the cell directory before it runs, so every byte of every
  file is in the trace and a replay from nothing is exact. Nothing here can check
  that assumption — a trace of a directory that already had files in it would
  reconstruct to something plausible and wrong — so it is the probe's job to
  delete the directory first, and it does.
  """

  @typedoc "A parsed trace record; `data_off` is -1 for records with no payload."
  @type record :: %{
          op: String.t(),
          path: String.t(),
          off: integer(),
          len: integer(),
          data_off: integer()
        }

  @doc """
  The files as they would be on disk if power were lost after `cut` records.

  A write landing past the end of its file zero-fills the gap, because that is
  what the filesystem does and because SQLite grows the WAL exactly that way.

  Returns `{:error, {:truncated_blob, path, offset}}` if a record points past the
  end of the payload blob. That means the trace and the blob disagree — a run
  killed mid-write, or the two files coming from different runs — and every byte
  after it would be silently wrong. Failing is the only safe answer: the output
  of this function is handed to SQLite, and a bad reconstruction does not look
  like a bad reconstruction. It looks like a corrupt database, which is precisely
  what tier 2 is hunting for.
  """
  @spec reconstruct([record()], binary(), non_neg_integer()) ::
          {:ok, %{String.t() => binary()}} | {:error, term()}
  def reconstruct(records, blob, cut) do
    records
    |> Enum.take(cut)
    |> Enum.reduce_while({:ok, %{}}, fn record, {:ok, files} ->
      case apply_record(record, blob, files) do
        {:ok, files} -> {:cont, {:ok, files}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_record(%{op: "write", data_off: -1}, _blob, files), do: {:ok, files}

  defp apply_record(%{op: "write"} = r, blob, files) do
    if r.data_off + r.len > byte_size(blob) do
      {:error, {:truncated_blob, r.path, r.data_off}}
    else
      {:ok, place(r, binary_part(blob, r.data_off, r.len), files)}
    end
  end

  defp apply_record(%{op: "truncate"} = r, _blob, files) do
    current = Map.get(files, r.path, <<>>)
    len = min(r.off, byte_size(current))
    {:ok, Map.put(files, r.path, binary_part(current, 0, len))}
  end

  defp apply_record(_record, _blob, files), do: {:ok, files}

  defp place(r, payload, files) do
    current = Map.get(files, r.path, <<>>)

    # off == -1 is a sequential write(2) rather than a pwrite(2). SQLite's unix
    # VFS uses pwrite for database and WAL I/O, so this is only reached by
    # something else writing into the traced directory -- append is the only
    # honest interpretation available.
    offset = if r.off == -1, do: byte_size(current), else: r.off

    if offset > byte_size(current) do
      padding = :binary.copy(<<0>>, offset - byte_size(current))
      Map.put(files, r.path, current <> padding <> payload)
    else
      head = binary_part(current, 0, offset)
      tail_start = offset + byte_size(payload)

      tail =
        if tail_start < byte_size(current),
          do: binary_part(current, tail_start, byte_size(current) - tail_start),
          else: <<>>

      Map.put(files, r.path, head <> payload <> tail)
    end
  end

  @doc """
  The cut points worth testing, as record indices.

  Every prefix is a legal crash state, but opening a database once per write is
  a lot of SQLite for very little extra coverage: the states that distinguish a
  correct implementation from a broken one are the ones around a barrier and
  around an acknowledgement. So this returns the index just before and just after
  every `SYNC` and every `MARK`, plus the end of the trace.

  Deliberately *not* thinned any further. An earlier version cut only at
  barriers, which cannot distinguish "acknowledged after the barrier" from
  "acknowledged before it" — the exact bug tier 1 exists to find.
  """
  @spec cut_points([record()]) :: [non_neg_integer()]
  def cut_points(records) do
    interesting =
      records
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{op: op}, i} when op in ["SYNC", "MARK"] -> [i, i + 1]
        _ -> []
      end)

    [0, length(records) | interesting]
    |> Enum.uniq()
    |> Enum.filter(&(&1 >= 0 and &1 <= length(records)))
    |> Enum.sort()
  end

  @doc """
  The commits that must survive a crash at `cut`.

  A commit must be present only if it was *both* acknowledged and made durable
  before the cut: its `MARK` appeared, and a barrier on the WAL followed the
  commit's last WAL write and preceded that `MARK`. Under `synchronous: :normal`
  this is empty for most cuts, which is the point — the probe still requires the
  database to be *valid*, only not to contain those writes.
  """
  @spec expected_commits([record()], non_neg_integer()) :: [String.t()]
  def expected_commits(records, cut) do
    records
    |> Enum.take(cut)
    |> AshCell.BarrierTrace.verdicts()
    |> Enum.filter(& &1.durable?)
    |> Enum.filter(&(&1.wal_writes > 0))
    |> Enum.map(& &1.label)
  end
end
