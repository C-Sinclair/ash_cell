# Tier 2 of ADR-20's "test that can fail": if the machine had lost power at an
# arbitrary point, would the database still open, and would every acknowledged
# and barriered commit still be there?
#
# Tier 1 (test/fault/barrier_probe.exs) asks whether a barrier was *requested*
# before an acknowledgement. It never opens the resulting bytes. This does: it
# replays the traced writes up to each interesting cut point, hands the result to
# SQLite, and asserts two things per cut.
#
#   1. The database opens and passes PRAGMA integrity_check. Required at EVERY
#      cut, under every durability level -- a crash must never leave an
#      unreadable database, and SQLite's WAL recovery is what guarantees it. This
#      assertion holds under `:normal` too, which is the point: `:normal` loses
#      recent commits, it does not corrupt.
#   2. Every commit that was acknowledged *and* barriered before the cut is
#      present. Under `:full` that is nearly all of them; under `:normal` it is
#      nearly none, and the probe expects exactly that rather than pretending
#      otherwise.
#
# Driven by scripts/barrier_test.sh --tier2. Linux only, for the reason in
# test/fault/barrier_shim.c.
#
# The crash model is a prefix of the issue order, which is what dm-log-writes'
# replay-log uses and is weaker than a real device in one known way: a drive may
# reorder writes between barriers, reaching states that are not prefixes. That
# needs the block layer, and is tier 3.

defmodule ReplayProbe do
  alias AshCell.BarrierReplay
  alias AshCell.BarrierTrace

  @rows 5
  @tenant "replay"

  def run do
    level = System.get_env("PROBE_SYNC", "normal") |> String.to_atom()

    workload(level, System.fetch_env!("SHIM_MARK"))

    records = System.fetch_env!("SHIM_LOG") |> File.read!() |> BarrierTrace.parse()
    blob = System.fetch_env!("SHIM_DATA") |> File.read!()
    scratch = Path.join(System.fetch_env!("PROBE_WORK"), "replay")

    IO.puts(
      "\nsynchronous: #{level} -- #{length(records)} records, #{byte_size(blob)} bytes captured"
    )

    cuts = BarrierReplay.cut_points(records)
    results = Enum.map(cuts, &check_cut(records, blob, scratch, &1))

    report(results, level)
  end

  defp workload(level, mark_dir) do
    dir = System.fetch_env!("PROBE_CELL_DIR")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.mkdir_p!(mark_dir)

    Application.put_env(:ash_cell, AshCell.TestRepo, synchronous: level)

    {:ok, _} =
      Supervisor.start_link(
        [{AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations}],
        strategy: :one_for_one
      )

    mark(mark_dir, "start")

    for i <- 1..@rows do
      AshCell.Test.TenantPatient.create!("Patient #{i}", tenant: @tenant)
      mark(mark_dir, "commit-#{i}")
    end

    # Closed and then waited on, so the cell's own shutdown -- which checkpoints,
    # truncates the WAL and deletes the sidecars -- is part of the recorded stream
    # rather than landing underneath the analysis.
    AshCell.close(@tenant)
    settle(System.fetch_env!("SHIM_LOG"))
  end

  # `AshCell.close/1` returns before the cell's connection has finished shutting
  # down, and that shutdown checkpoints -- `AshCell.Cell` documents it as
  # happening "asynchronously, after this process is gone". Reading the trace
  # immediately therefore analyses an accidental prefix of the run, and the
  # records it misses are the interesting ones: the checkpoint's writes into the
  # `.db`, the WAL truncation, and the deletion of the sidecars. Measured: 68 of
  # 78 records were present without this wait.
  #
  # Settling on size rather than waiting a fixed time, so a slow machine gets
  # more and a fast one is not punished.
  defp settle(path, stable_for \\ 300, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_quiet(path, size(path), stable_for, deadline)
  end

  defp wait_for_quiet(path, last, stable_for, deadline) do
    Process.sleep(stable_for)
    now = size(path)

    cond do
      now == last -> :ok
      System.monotonic_time(:millisecond) > deadline -> :ok
      true -> wait_for_quiet(path, now, stable_for, deadline)
    end
  end

  defp size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp mark(dir, label), do: File.read(Path.join(dir, label))

  defp check_cut(records, blob, scratch, cut) do
    File.rm_rf!(scratch)
    File.mkdir_p!(scratch)

    with {:ok, files} <- BarrierReplay.reconstruct(records, blob, cut),
         :ok <- materialise(files, scratch),
         {:ok, db} <- locate_db(scratch) do
      expected = BarrierReplay.expected_commits(records, cut)

      # A zero-byte file is a *valid* empty SQLite database, so integrity_check
      # passes on it and the cut looks readable while containing nothing. That
      # masked the real problem the first time: the reconstruction was producing
      # empty files at late cuts and the probe reported it as lost data.
      case File.stat!(db) do
        %{size: 0} when expected != [] ->
          %{cut: cut, status: :error, reason: "reconstructed a 0-byte database"}

        _ ->
          verify(db, cut, expected)
      end
    else
      # No database file yet is a legitimate state: the cut lands before the cell
      # ever created one. It is not a pass or a failure, it is nothing to check.
      :no_database -> %{cut: cut, status: :empty}
      {:error, reason} -> %{cut: cut, status: :error, reason: reason}
    end
  end

  # The -shm is deliberately not written out. It is a volatile index that SQLite
  # rebuilds on open, and a real power failure loses it; carrying a reconstructed
  # one across would let the replay recover from state a rebooted machine does
  # not have.
  defp materialise(files, scratch) do
    Enum.each(files, fn {path, bytes} ->
      unless String.ends_with?(path, "-shm") do
        File.write!(Path.join(scratch, Path.basename(path)), bytes)
      end
    end)
  end

  defp locate_db(scratch) do
    case scratch |> Path.join("*.db") |> Path.wildcard() do
      [db | _] -> {:ok, db}
      [] -> :no_database
    end
  end

  defp verify(db, cut, expected) do
    {:ok, conn} = Exqlite.Sqlite3.open(db)

    try do
      with :ok <- integrity(conn),
           {:ok, present} <- names(conn) do
        case expected -- present do
          [] ->
            %{cut: cut, status: :ok, present: length(present), expected: length(expected)}

          missing ->
            %{cut: cut, status: :lost, missing: missing, present: present, sizes: sizes(db)}
        end
      end
    rescue
      e -> %{cut: cut, status: :error, reason: Exception.message(e)}
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  # Printed with every loss, because the first run of this probe reported losses
  # it could not explain and the file sizes were the missing clue: a `.db` that is
  # too small next to an emptied `-wal` means the checkpoint's pages never made it
  # into the trace, which is a gap in the capture rather than a lost write.
  defp sizes(db) do
    [{"db", db}, {"wal", db <> "-wal"}]
    |> Enum.map_join(" ", fn {label, path} ->
      case File.stat(path) do
        {:ok, %{size: size}} -> "#{label}=#{size}"
        _ -> "#{label}=absent"
      end
    end)
  end

  defp integrity(conn) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "PRAGMA integrity_check")

    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, ["ok"]} -> :ok
      {:row, [problem]} -> %{status: :corrupt, reason: problem}
      other -> %{status: :corrupt, reason: inspect(other)}
    end
  end

  # A commit is identified by the row it wrote, so "did this survive" is a query
  # rather than an inference from the trace.
  #
  # The table is `tenant_patients`, which `AshCell.Test.TenantPatient` writes.
  # Querying `patients` instead cost several rounds of investigation and looked
  # exactly like data loss: that table also exists, because the migration creates
  # both, so the query succeeded and returned nothing. Every expected commit was
  # then reported missing from a database that in fact held all of them.
  #
  # "No such table" and "could not read the table" are separated deliberately.
  # An earlier version rescued both to an empty list, which turned every failure
  # to read into a report of lost data -- a harness bug wearing the costume of the
  # exact finding this tier exists to produce. A missing table is a legitimate
  # crash state; anything else is the harness failing and must say so.
  defp names(conn) do
    case Exqlite.Sqlite3.prepare(conn, "SELECT name FROM tenant_patients") do
      {:ok, stmt} ->
        case Exqlite.Sqlite3.fetch_all(conn, stmt) do
          {:ok, rows} -> {:ok, rows |> List.flatten() |> Enum.map(&commit_label/1)}
          {:error, reason} -> %{status: :error, reason: "fetch_all: #{inspect(reason)}"}
        end

      {:error, reason} ->
        message = to_string(inspect(reason))

        if String.contains?(message, "no such table") do
          # The cut landed before the migration was durable. A valid crash state.
          {:ok, []}
        else
          %{status: :error, reason: "prepare: #{message}"}
        end
    end
  end

  defp commit_label("Patient " <> i), do: "commit-#{i}"
  defp commit_label(other), do: other

  # The whole trace, indexed, printed only on failure. It is tens of records, and
  # the alternative is guessing: the first two failures of this probe were both
  # diagnosed from what the reconstruction produced rather than from the writes
  # that produced it, and both guesses were wrong.
  defp dump(records) do
    IO.puts("\n  trace (index: op path offset length):")

    records
    |> Enum.with_index()
    |> Enum.each(fn {r, i} ->
      IO.puts(
        "    #{String.pad_leading("#{i}", 3)}: #{r.op} #{Path.basename(r.path)} #{r.off} #{r.len}"
      )
    end)

    IO.puts("")
  end

  defp records do
    System.fetch_env!("SHIM_LOG") |> File.read!() |> BarrierTrace.parse()
  end

  defp report(results, level) do
    by_status = Enum.group_by(results, & &1.status)
    corrupt = Map.get(by_status, :corrupt, []) ++ Map.get(by_status, :error, [])
    lost = Map.get(by_status, :lost, [])
    ok = Map.get(by_status, :ok, [])
    empty = Map.get(by_status, :empty, [])

    IO.puts("""

      #{length(results)} cut points replayed
      #{length(ok)} valid, #{length(empty)} before any database existed, \
    #{length(corrupt)} unreadable, #{length(lost)} lost an acknowledged commit
    """)

    cond do
      corrupt != [] ->
        dump(records())
        IO.puts("FAIL -- a crash left an unreadable database. This is corruption, not staleness:")
        Enum.each(Enum.take(corrupt, 5), &IO.puts("  cut #{&1.cut}: #{inspect(&1[:reason])}"))
        System.halt(1)

      lost != [] ->
        dump(records())
        IO.puts("FAIL -- commits that were acknowledged and barriered did not survive:")

        Enum.each(
          Enum.take(lost, 5),
          &IO.puts(
            "  cut #{&1.cut}: missing #{inspect(&1.missing)}, " <>
              "present #{inspect(&1.present)}, #{&1.sizes}"
          )
        )

        System.halt(1)

      ok == [] ->
        IO.puts("""
        FAIL -- no cut point produced a readable database.

        Nothing was actually verified. This is what an empty or unmatched trace
        looks like, and it must not be read as a pass.
        """)

        System.halt(1)

      true ->
        IO.puts("""
        PASS -- every reachable crash state left a database that opens and passes
        integrity_check, and no acknowledged, barriered commit was lost.
        #{surviving(ok, level)}
        """)
    end
  end

  defp surviving(ok, level) do
    total = ok |> Enum.map(& &1.expected) |> Enum.sum()

    "Across all cuts, #{total} commit-survivals were required and met under `#{level}`."
  end
end

ReplayProbe.run()
