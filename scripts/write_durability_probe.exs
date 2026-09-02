# Probe: what does a durable COMMIT cost, and does batching make it affordable?
#
# ADR-20 is open because the choice between `synchronous: :normal` and `:full` was
# never measured. exqlite defaults to `:normal`, which in WAL mode does not fsync at
# commit at all -- it fsyncs at checkpoint -- so the loss window on power failure is
# the whole WAL, not the last transaction. `:full` closes that. Nobody knew the price.
#
# This measures the price. It measures nothing else, and in particular:
#
#   * It does NOT show that `:full` survives a power cut. That needs a machine
#     boundary -- a VM whose power is cut, or dm-log-writes replaying the block
#     stream to a prefix -- and is ADR-20's step 2. A number here cannot close the
#     ADR on its own.
#   * On macOS the numbers for `:full` are optimistic to the point of being wrong.
#     Darwin's fsync returns without flushing the drive's write cache; only
#     F_FULLFSYNC does. The `full + fullfsync` row is what `:full` actually costs
#     when it means what it says, and the gap between the two rows is the size of
#     the lie. On Linux, `fullfsync` is a no-op and the two rows should match.
#
# The batch axis is the point of the probe. An fsync is per *commit*, not per row,
# so if grouping writes amortises it then the tradeoff changes shape entirely and
# `:full` stops being a throughput decision.
#
# On reading the output: the levels that do not fsync are dominated by the round-trip
# cost of driving 3 statements per commit through DBConnection, not by SQLite. The
# `statement floor` row measures that overhead on its own -- subtract it before
# reading anything into a gap between `off` and `normal`. It is also why every row
# carries its min and its spread rather than a lone median: on a laptop the noise
# between runs of an unsynced level exceeded 10x, and a median alone would have
# reported that as a result. Trust a gap only when it is wider than the spread.
#
#     mix run scripts/write_durability_probe.exs

defmodule DurabilityProbe.Repo do
  use AshSqlite.Repo, otp_app: :ash_cell
  def installed_extensions, do: []
end

defmodule DurabilityProbe do
  @rows 1_000
  @batches [1, 10, 100]
  @reps 9

  # `:off` is included as the floor -- the cost of the write with no durability at
  # all -- so the other levels can be read as a multiple of the work itself rather
  # than of each other. It is not a candidate: an OS crash under `:off` can corrupt
  # the database rather than merely truncate it.
  @levels [
    {:off, false},
    {:normal, false},
    {:full, false},
    {:full, true},
    {:extra, false}
  ]

  def run do
    dir = Path.join(System.tmp_dir!(), "ash_cell_durability_probe")

    IO.puts("""

    #{@rows} single-row inserts, one writer, pool_size: 1 (as a cell runs).
    OTP #{:erlang.system_info(:otp_release)}, #{:erlang.system_info(:schedulers_online)} \
    schedulers, #{:erlang.system_info(:system_architecture)}
    #{platform_note()}
    """)

    for batch <- @batches do
      commits = div(@rows, batch)

      IO.puts("""

      Batch #{batch} row#{if batch == 1, do: "", else: "s"} per transaction \
      -- #{commits} commit#{if commits == 1, do: "", else: "s"}
      #{String.pad_trailing("", 74, "-")}\
      """)

      header()

      floor_row(dir, commits, batch)

      for {level, fullfsync?} <- @levels do
        report(label(level, fullfsync?), commits, fn ->
          measure(dir, level, fullfsync?, batch)
        end)
      end
    end

    File.rm_rf!(dir)
    IO.puts("")
  end

  defp platform_note do
    case :os.type() do
      {:unix, :darwin} ->
        "macOS: plain fsync does not flush the drive cache. Read the fullfsync row."

      _ ->
        "fullfsync is a Darwin-only pragma; its row should match plain full here."
    end
  end

  defp label(level, false), do: to_string(level)
  defp label(level, true), do: "#{level} + fullfsync"

  # A fresh database per measurement. Reusing one would let a growing table, a
  # warm page cache and an unpredictable autocheckpoint carry between levels, and
  # the checkpoint is exactly where `:normal` pays what it deferred -- averaging it
  # across a run that started warm would flatter whichever level went second.
  defp measure(dir, level, fullfsync?, batch) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "cell.db")

    {:ok, repo_pid} =
      DurabilityProbe.Repo.start_link(
        name: nil,
        database: path,
        pool_size: 1,
        journal_mode: :wal,
        synchronous: level,
        log: false,
        backoff_type: :stop
      )

    if fullfsync? do
      Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA fullfsync = 1", [])
      Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA checkpoint_fullfsync = 1", [])
    end

    Ecto.Adapters.SQL.query!(
      repo_pid,
      "CREATE TABLE entries (id INTEGER PRIMARY KEY, body TEXT NOT NULL, at INTEGER NOT NULL)",
      []
    )

    # Warm the connection so the first statement's setup is not counted as an fsync.
    Ecto.Adapters.SQL.query!(repo_pid, "SELECT 1", [])

    micros = time(fn -> write_all(repo_pid, batch) end)

    Supervisor.stop(repo_pid)
    micros
  end

  # BEGIN IMMEDIATE, matching what AshCell.transaction/2 opens. A batch of 1 is
  # still an explicit transaction rather than autocommit, so the batch axis varies
  # only the number of commits and not the statement shape.
  defp write_all(repo_pid, batch) do
    1..@rows
    |> Enum.chunk_every(batch)
    |> Enum.each(fn chunk ->
      Ecto.Adapters.SQL.query!(repo_pid, "BEGIN IMMEDIATE", [])

      Enum.each(chunk, fn i ->
        Ecto.Adapters.SQL.query!(
          repo_pid,
          "INSERT INTO entries (body, at) VALUES (?1, ?2)",
          ["entry body #{i} with enough text to be a realistic row", i]
        )
      end)

      Ecto.Adapters.SQL.query!(repo_pid, "COMMIT", [])
    end)
  end

  defp time(fun) do
    {micros, _} = :timer.tc(fun)
    micros
  end

  defp header do
    IO.puts(
      String.pad_trailing("level", 20) <>
        String.pad_leading("median", 10) <>
        String.pad_leading("min", 10) <>
        String.pad_leading("min/commit", 14) <>
        String.pad_leading("min/row", 11) <>
        String.pad_leading("spread", 9)
    )
  end

  # Reported as median, min, and spread (max/min) over #{@reps} runs after a warmup.
  # The min is the least-contaminated estimate -- background noise on a shared
  # machine is additive, so the fastest run is the closest to the cost of the work
  # itself -- and the spread is what says whether to believe any of it. A row whose
  # spread is wider than its distance from the next row has not measured anything.
  defp report(label, commits, fun) do
    fun.()

    runs = Enum.map(1..@reps, fn _ -> fun.() end) |> Enum.sort()
    median = Enum.at(runs, div(@reps, 2))
    min = hd(runs)
    spread = List.last(runs) / min

    IO.puts(
      String.pad_trailing(label, 20) <>
        String.pad_leading("#{round(median / 1000)} ms", 10) <>
        String.pad_leading("#{round(min / 1000)} ms", 10) <>
        String.pad_leading("#{Float.round(min / commits, 1)} µs", 14) <>
        String.pad_leading("#{Float.round(min / @rows, 1)} µs", 11) <>
        String.pad_leading("#{Float.round(spread, 1)}x", 9)
    )
  end

  # The cost of getting a statement to SQLite and back, with no durability decision
  # involved. Three statements per commit is what the batch-1 rows above pay
  # (BEGIN, INSERT, COMMIT), so this is the floor those rows cannot go below.
  defp floor_row(dir, commits, batch) do
    report("statement floor", commits, fn -> measure_floor(dir, batch) end)
  end

  defp measure_floor(dir, batch) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    {:ok, repo_pid} =
      DurabilityProbe.Repo.start_link(
        name: nil,
        database: Path.join(dir, "floor.db"),
        pool_size: 1,
        journal_mode: :wal,
        synchronous: :off,
        log: false,
        backoff_type: :stop
      )

    Ecto.Adapters.SQL.query!(repo_pid, "SELECT 1", [])
    statements = div(@rows, batch) * 2 + @rows

    micros =
      time(fn ->
        Enum.each(1..statements, fn _ ->
          Ecto.Adapters.SQL.query!(repo_pid, "SELECT 1", [])
        end)
      end)

    Supervisor.stop(repo_pid)
    micros
  end
end

DurabilityProbe.run()
