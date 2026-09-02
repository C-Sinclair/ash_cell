defmodule AshCell.BarrierTraceTest do
  @moduledoc """
  The judgement half of ADR-20 tier 1, tested against synthetic traces.

  The probe itself cannot run here — it needs `LD_PRELOAD` to reach `beam.smp`,
  and macOS strips `DYLD_INSERT_LIBRARIES` under SIP before the BEAM starts. So
  the analysis is a module and this covers it everywhere, which matters more than
  it sounds: a fault-injection harness whose *verdict* is wrong reports a
  guarantee it never checked, and that failure is silent in exactly the way
  ADR-20 warns about.
  """
  use ExUnit.Case, async: true

  alias AshCell.BarrierTrace

  defp trace(lines) do
    lines
    |> Enum.map_join("\n", fn
      {op, path} -> "#{op}\t#{path}\t0\t0"
    end)
    |> BarrierTrace.parse()
  end

  @wal "/cells/acme.db-wal"
  @db "/cells/acme.db"

  describe "the invariant" do
    test "a commit whose WAL write was synced before the ack is durable" do
      verdicts =
        trace([
          {"MARK", "start"},
          {"write", @wal},
          {"SYNC", @wal},
          {"MARK", "commit-1"}
        ])
        |> BarrierTrace.verdicts()

      assert [%{label: "commit-1", durable?: true, wal_writes: 1, wal_syncs: 1}] = verdicts
      assert BarrierTrace.violations(verdicts) == []
    end

    test "a commit acknowledged with no sync at all is a violation" do
      verdicts =
        trace([
          {"MARK", "start"},
          {"write", @wal},
          {"MARK", "commit-1"}
        ])
        |> BarrierTrace.verdicts()

      assert [%{label: "commit-1", durable?: false}] = verdicts
      assert [%{label: "commit-1"}] = BarrierTrace.violations(verdicts)
    end

    # The ordering is the whole point. A sync that ran *before* the write it is
    # supposed to cover is not a barrier for it, and a check that merely counted
    # syncs per window would call this durable.
    test "a sync that precedes the write it should cover is a violation" do
      verdicts =
        trace([
          {"MARK", "start"},
          {"SYNC", @wal},
          {"write", @wal},
          {"MARK", "commit-1"}
        ])
        |> BarrierTrace.verdicts()

      assert [%{label: "commit-1", durable?: false, wal_syncs: 1}] = verdicts
    end

    test "a sync of the database file is not a barrier for the WAL" do
      verdicts =
        trace([
          {"MARK", "start"},
          {"write", @wal},
          {"SYNC", @db},
          {"MARK", "commit-1"}
        ])
        |> BarrierTrace.verdicts()

      assert [%{label: "commit-1", durable?: false, wal_syncs: 0}] = verdicts
    end

    test "a window that never wrote the WAL is durable, not a violation" do
      verdicts =
        trace([
          {"MARK", "start"},
          {"write", @db},
          {"MARK", "read-only-action"}
        ])
        |> BarrierTrace.verdicts()

      assert [%{label: "read-only-action", durable?: true, wal_writes: 0}] = verdicts
    end

    test "a later commit's sync does not retroactively make an earlier one durable" do
      verdicts =
        trace([
          {"MARK", "start"},
          {"write", @wal},
          {"MARK", "commit-1"},
          {"write", @wal},
          {"SYNC", @wal},
          {"MARK", "commit-2"}
        ])
        |> BarrierTrace.verdicts()

      assert [
               %{label: "commit-1", durable?: false},
               %{label: "commit-2", durable?: true}
             ] = verdicts
    end
  end

  describe "windowing" do
    # Everything before the first MARK is the cell opening and migrating. Counting
    # it as a commit would report a violation on every run, under every level,
    # and the noise would bury a real one.
    test "records before the first mark are not a commit" do
      verdicts =
        trace([
          {"write", @wal},
          {"write", @db},
          {"MARK", "start"},
          {"write", @wal},
          {"SYNC", @wal},
          {"MARK", "commit-1"}
        ])
        |> BarrierTrace.verdicts()

      assert [%{label: "commit-1"}] = verdicts
    end

    test "each verdict keeps the label of the mark that closed its window" do
      labels =
        trace([
          {"MARK", "start"},
          {"write", @wal},
          {"SYNC", @wal},
          {"MARK", "commit-1"},
          {"write", @wal},
          {"SYNC", @wal},
          {"MARK", "commit-2"},
          {"write", @wal},
          {"SYNC", @wal},
          {"MARK", "commit-3"}
        ])
        |> BarrierTrace.verdicts()
        |> Enum.map(& &1.label)

      assert labels == ["commit-1", "commit-2", "commit-3"]
    end

    test "a trace with no marks yields no verdicts rather than one giant window" do
      assert trace([{"write", @wal}, {"SYNC", @wal}]) |> BarrierTrace.verdicts() == []
    end
  end

  describe "parse/1" do
    test "drops lines that are not four tab-separated fields" do
      assert BarrierTrace.parse("write\t/a-wal\t0\t4096\ngarbage\n\nSYNC\t/a-wal\t0\t0\n")
             |> Enum.map(& &1.op) == ["write", "SYNC"]
    end
  end
end
