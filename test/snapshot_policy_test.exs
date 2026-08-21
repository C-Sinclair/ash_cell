defmodule AshCell.SnapshotPolicyTest do
  @moduledoc """
  The decision of whether to ship, separated from the shipping.

  Kept as pure function tests because the alternative -- asserting on timers and a
  real bucket -- is slow, flaky, and tests the scheduler rather than the policy. The
  integration is covered in `AshCell.PeriodicSnapshotTest`.
  """
  use ExUnit.Case, async: true

  alias AshCell.SnapshotPolicy

  describe "construction" do
    test "is on by default when the fleet has a store" do
      policy = SnapshotPolicy.new(nil, store: :some_store)

      assert policy.enabled?
    end

    test "is off when the fleet has no store, because there is nowhere to ship" do
      # Not a misconfiguration. A local fleet with no bucket is supported.
      refute SnapshotPolicy.new(nil, []).enabled?
      refute SnapshotPolicy.new([wal_bytes: 1], []).enabled?
    end

    test "can be turned off explicitly for a fleet that ships only on drain" do
      refute SnapshotPolicy.new(false, store: :some_store).enabled?
    end

    test "takes both thresholds from options" do
      policy =
        SnapshotPolicy.new([wal_bytes: 123, max_age_ms: 456, interval_ms: 789],
          store: :some_store
        )

      assert policy.wal_bytes == 123
      assert policy.max_age_ms == 456
      assert policy.interval_ms == 789
    end
  end

  describe "deciding whether to ship" do
    setup do
      {:ok, policy: SnapshotPolicy.new([wal_bytes: 1_000, max_age_ms: 10_000], store: :s)}
    end

    test "ships once the WAL is past the size threshold", %{policy: policy} do
      refute SnapshotPolicy.ship?(policy, 999, 0)
      assert SnapshotPolicy.ship?(policy, 1_000, 0)
      assert SnapshotPolicy.ship?(policy, 5_000, 0)
    end

    test "ships a small amount of unshipped data once it is old enough", %{policy: policy} do
      # The low-traffic tenant whose single write matters most. Size alone would
      # leave this unshipped indefinitely.
      refute SnapshotPolicy.ship?(policy, 1, 9_999)
      assert SnapshotPolicy.ship?(policy, 1, 10_000)
    end

    test "never ships a cell with an empty WAL, however old", %{policy: policy} do
      # A dormant cell must cost nothing. This matters more the smaller and more
      # numerous cells get: a whole-file PUT for a cell nobody wrote to is waste.
      refute SnapshotPolicy.ship?(policy, 0, 0)
      refute SnapshotPolicy.ship?(policy, 0, 10_000)
      refute SnapshotPolicy.ship?(policy, 0, :timer.hours(24))
    end

    test "never ships when disabled", %{policy: policy} do
      off = %{policy | enabled?: false}

      refute SnapshotPolicy.ship?(off, 1_000_000, :timer.hours(24))
    end
  end

  describe "the schedule" do
    test "spreads first ticks across the interval" do
      # The first tick decides whether a fleet activating together is spread out at
      # all, so it must not be a constant.
      policy = SnapshotPolicy.new([interval_ms: 1_000], store: :s)

      delays = for _ <- 1..200, do: SnapshotPolicy.initial_delay(policy)

      assert Enum.all?(delays, &(&1 >= 1 and &1 <= 1_000))
      assert length(Enum.uniq(delays)) > 50, "initial delay is not being spread"
    end

    test "re-jitters every tick so cells drift apart rather than march together" do
      policy = SnapshotPolicy.new([interval_ms: 1_000], store: :s)

      delays = for _ <- 1..200, do: SnapshotPolicy.next_delay(policy)

      assert Enum.all?(delays, &(&1 >= 500 and &1 <= 1_500))
      assert length(Enum.uniq(delays)) > 50, "tick delay is not being jittered"
    end

    test "never returns a non-positive delay, even for a tiny interval" do
      # Process.send_after/3 with 0 is legal but a busy loop; negative raises.
      for interval <- [1, 2, 3, 10] do
        policy = SnapshotPolicy.new([interval_ms: interval], store: :s)

        assert SnapshotPolicy.initial_delay(policy) > 0
        assert SnapshotPolicy.next_delay(policy) > 0
      end
    end
  end

  describe "reading the WAL size" do
    test "is 0 when there is no WAL beside the database" do
      assert SnapshotPolicy.wal_bytes(Path.join(System.tmp_dir!(), "definitely-not-here.db")) == 0
    end

    test "is the size of the -wal sidecar" do
      path = Path.join(System.tmp_dir!(), "wal_test_#{System.unique_integer([:positive])}.db")
      File.write!(path <> "-wal", "12345")
      on_exit(fn -> File.rm(path <> "-wal") end)

      assert SnapshotPolicy.wal_bytes(path) == 5
    end
  end
end
