# Tier 1 of ADR-20's "test that can fail": does an acknowledged COMMIT actually
# request a durability barrier before it returns?
#
# Driven by scripts/barrier_test.sh, which builds test/fault/barrier_shim.c and
# runs this under LD_PRELOAD. Linux only -- see the shim for why macOS cannot.
#
# This file is the workload and the expectations. The judgement lives in
# AshCell.BarrierTrace, tested by test/barrier_trace_test.exs, because a harness
# whose verdict is wrong reports a guarantee it never checked.
#
# The workload writes through a real cell -- AshCell.Manager, AshCell.Cell, an Ash
# action, a real transaction -- rather than a bare Ecto repo, because the question
# is what *this stack* acknowledges, not what SQLite does in isolation. After each
# write returns to Elixir it opens a path under SHIM_MARK, which the shim records
# as a MARK in the syscall stream; that interleaving is what makes "before the
# ack" checkable rather than a wall-clock guess.
#
# Both levels are asserted, in opposite directions:
#
#   :full   -- every acknowledged commit must be preceded by a WAL barrier. This
#              is the guarantee, and a regression is a lost-data bug.
#   :normal -- must show violations. If it ever stops, the probe's premise is
#              wrong: either SQLite changed or the trace is not capturing what it
#              thinks it is, and a green :full run would be false comfort.

defmodule BarrierProbe do
  alias AshCell.BarrierTrace

  @rows 5
  @tenant "barrier"

  def run do
    level = System.get_env("PROBE_SYNC", "normal") |> String.to_atom()
    fullfsync? = System.get_env("PROBE_FULLFSYNC") == "1"
    mark_dir = System.fetch_env!("SHIM_MARK")

    workload(level, fullfsync?, mark_dir)

    verdicts =
      System.fetch_env!("SHIM_LOG")
      |> File.read!()
      |> BarrierTrace.parse()
      |> BarrierTrace.verdicts()

    report(verdicts, level, fullfsync?)
    judge(level, verdicts, BarrierTrace.violations(verdicts))
  end

  defp workload(level, fullfsync?, mark_dir) do
    dir = System.fetch_env!("PROBE_CELL_DIR")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.mkdir_p!(mark_dir)

    # Reaches the cell's connection because AshCell.Cell passes no :synchronous
    # and Ecto merges a repo's application config underneath the options it is
    # given. The probe sets the level by the same route an application would,
    # rather than by a private hook -- so this also tests that the documented
    # mechanism works.
    Application.put_env(:ash_cell, AshCell.TestRepo, synchronous: level)

    {:ok, _} =
      Supervisor.start_link(
        [{AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations}],
        strategy: :one_for_one
      )

    if fullfsync?, do: set_fullfsync()

    # Activation and migration happen before the first mark, so schema I/O is
    # never attributed to a commit under test.
    mark(mark_dir, "start")

    for i <- 1..@rows do
      AshCell.Test.TenantPatient.create!("Patient #{i}", tenant: @tenant)
      mark(mark_dir, "commit-#{i}")
    end

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

  defp set_fullfsync do
    {:ok, pid} = AshCell.Manager.ensure_started(@tenant)
    repo_pid = AshCell.Cell.repo_pid(pid)
    Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA fullfsync = 1", [])
    Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA checkpoint_fullfsync = 1", [])
  end

  # An open(2) on a path that does not exist is still an open(2), so this needs no
  # file and leaves nothing behind. File.read/1 rather than File.open/2 because it
  # does not care that the open failed.
  defp mark(dir, label), do: File.read(Path.join(dir, label))

  defp report(verdicts, level, fullfsync?) do
    IO.puts(
      "\nsynchronous: #{level}#{if fullfsync?, do: " + fullfsync", else: ""} " <>
        "-- #{length(verdicts)} acknowledged commits\n"
    )

    Enum.each(verdicts, fn v ->
      IO.puts(
        "  " <>
          String.pad_trailing(v.label, 12) <>
          String.pad_leading("#{v.wal_writes} wal writes", 16) <>
          String.pad_leading("#{v.wal_syncs} wal syncs", 15) <>
          "   " <> if(v.durable?, do: "durable", else: "NOT DURABLE")
      )
    end)
  end

  # A trace with no commits at all is a broken harness, not a pass. It is the
  # shape a missed interposition takes -- the workload ran, nothing was recorded,
  # and every assertion below would be vacuously true.
  defp judge(_level, [], _violations) do
    fail("""
    no acknowledged commits were found in the trace.

    The workload ran but nothing was recorded, so the interposer did not attach or
    SHIM_MATCH does not match the cell directory. Do not read this as a pass.
    """)
  end

  defp judge(:full, verdicts, []) do
    IO.puts("\nPASS -- all #{length(verdicts)} acknowledged commits synced the WAL first.")
  end

  defp judge(:full, _verdicts, violations) do
    fail("""
    #{length(violations)} acknowledged commits were not made durable:
    #{Enum.map_join(violations, "\n", &"  - #{&1.label}")}

    An acknowledged write can be lost on power failure. This is the invariant
    ADR-20 exists to protect.
    """)
  end

  defp judge(:normal, verdicts, []) do
    fail("""
    expected `:normal` to acknowledge commits without syncing the WAL, and it
    synced all #{length(verdicts)}.

    The probe is not measuring what it claims: either SQLite's behaviour changed,
    or the trace is missing the writes. Until that is explained, do not read a
    green `:full` run as a guarantee.
    """)
  end

  defp judge(:normal, verdicts, violations) do
    IO.puts("""

    PASS (expected gap) -- #{length(violations)} of #{length(verdicts)} commits were \
    acknowledged with no WAL barrier.
    This is the exposure ADR-20 records, reproduced. It is the fleet default.
    """)
  end

  defp fail(message) do
    IO.puts("\nFAIL -- " <> message)
    System.halt(1)
  end
end

BarrierProbe.run()
