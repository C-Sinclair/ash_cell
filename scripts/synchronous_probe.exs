# Probe: what does each SQLite durability level cost a cell's commits?
#
# ADR-20 asks for this before choosing between `synchronous: :normal`, exqlite's
# default and what every cell runs today, and `:full`. It measures commit latency on
# one WAL-mode file, the shape a cell is, for one insert per transaction and for
# batches of 10 and 100 inserts per transaction, the group commit that would amortise
# an fsync. On macOS `fsync` does not reach stable storage, so `:full` is also
# measured with `PRAGMA fullfsync = ON`, which issues `F_FULLFSYNC`.
#
# This measures cost only. Whether a level survives a power cut is not observable
# by killing a process, because the page cache outlives it; see ADR-20.
#
#     mix run scripts/synchronous_probe.exs

defmodule SynchronousProbe do
  alias Exqlite.Sqlite3

  @transactions 500
  @runs 5

  @levels [
    {"normal", ["PRAGMA synchronous = NORMAL"]},
    {"full", ["PRAGMA synchronous = FULL"]},
    {"full + fullfsync", ["PRAGMA synchronous = FULL", "PRAGMA fullfsync = ON"]},
    {"extra + fullfsync", ["PRAGMA synchronous = EXTRA", "PRAGMA fullfsync = ON"]}
  ]

  def run do
    dir = Path.join(System.tmp_dir!(), "ash_cell_synchronous_probe")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    IO.puts("""

    One WAL-mode file per level on #{dir}, #{@transactions} transactions per run,
    median of #{@runs} runs. µs per transaction (median across runs; p99 within the
    median run).
    """)

    for rows <- [1, 10, 100] do
      IO.puts("#{rows} insert(s) per transaction")

      for {label, pragmas} <- @levels do
        samples =
          for run <- 1..@runs do
            measure(
              Path.join(dir, "#{String.replace(label, ~r/\W+/, "_")}_#{rows}_#{run}.db"),
              pragmas,
              rows
            )
          end

        medians = Enum.map(samples, & &1.median)
        median_run = Enum.at(Enum.sort_by(samples, & &1.median), div(@runs, 2))

        IO.puts(
          "  #{String.pad_trailing(label, 18)} median #{fmt(median(medians))} µs, " <>
            "p99 #{fmt(median_run.p99)} µs, #{fmt(rows * 1_000_000 / median(medians))} rows/s"
        )
      end

      IO.puts("")
    end
  end

  defp measure(path, pragmas, rows) do
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
    for pragma <- pragmas, do: :ok = Sqlite3.execute(db, pragma)
    :ok = Sqlite3.execute(db, "CREATE TABLE rows (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
    {:ok, insert} = Sqlite3.prepare(db, "INSERT INTO rows (body) VALUES (?1)")

    times =
      for _ <- 1..@transactions do
        {us, :ok} =
          :timer.tc(fn ->
            :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

            for _ <- 1..rows do
              :ok = Sqlite3.bind(insert, ["a row about the size of a small record"])
              :done = Sqlite3.step(db, insert)
            end

            Sqlite3.execute(db, "COMMIT")
          end)

        us
      end

    :ok = Sqlite3.release(db, insert)
    :ok = Sqlite3.close(db)

    sorted = Enum.sort(times)

    %{
      median: Enum.at(sorted, div(length(sorted), 2)),
      p99: Enum.at(sorted, trunc(length(sorted) * 0.99))
    }
  end

  defp median(values), do: values |> Enum.sort() |> Enum.at(div(length(values), 2))

  defp fmt(value),
    do: value |> Kernel.*(1.0) |> Float.round(1) |> :erlang.float_to_binary(decimals: 1)
end

SynchronousProbe.run()
