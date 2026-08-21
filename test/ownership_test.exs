defmodule AshCell.OwnershipTest do
  @moduledoc """
  Read fencing.

  Conditional writes already guarantee no acknowledged write is lost. These tests
  cover the gap that leaves: a displaced node that can still reach clients will
  happily answer reads from a database somebody else now owns.
  """
  use ExUnit.Case, async: true

  alias AshCell.{Lease, Ownership}

  defp lease(owner \\ "node-a", generation \\ 1) do
    %Lease{cell_key: "acme", owner: owner, etag: "etag", generation: generation, expires_at: 0}
  end

  describe "bounded staleness" do
    test "a live lease may serve reads" do
      ownership = Ownership.held(lease(), 30_000)
      assert :ok = Ownership.check(ownership, :bounded)
    end

    test "an expired lease may not" do
      ownership = Ownership.held(lease(), 1)
      Process.sleep(20)

      assert {:error, {:lease_expired, overdue}} = Ownership.check(ownership, :bounded)
      assert overdue > 0
    end

    test "having no lease at all is refused, not treated as permission" do
      assert {:error, :no_lease} = Ownership.check(nil, :bounded)
    end

    test ":none serves regardless, for workloads where stale reads are harmless" do
      ownership = Ownership.held(lease(), 1)
      Process.sleep(20)

      assert :ok = Ownership.check(ownership, :none)
    end
  end

  describe "renewal timing" do
    test "renewal is due well before expiry, so one slow renewal is survivable" do
      ownership = Ownership.held(lease(), 300)
      refute Ownership.renew_due?(ownership)

      Process.sleep(220)

      assert Ownership.renew_due?(ownership)
      # Still allowed to serve: due for renewal is not the same as expired.
      assert :ok = Ownership.check(ownership, :bounded)
    end

    test "remaining time never goes negative" do
      ownership = Ownership.held(lease(), 1)
      Process.sleep(20)

      assert Ownership.remaining_ms(ownership) == 0
    end
  end

  describe "with_ownership" do
    test "runs the read when ownership holds" do
      ownership = Ownership.held(lease(), 30_000)
      assert {:ok, :rows} = Ownership.with_ownership(ownership, :bounded, fn -> :rows end)
    end

    test "refuses the read rather than returning stale data" do
      ownership = Ownership.held(lease(), 1)
      Process.sleep(20)

      assert {:error, {:lease_expired, _}} =
               Ownership.with_ownership(ownership, :bounded, fn -> :stale_rows end)
    end
  end

  describe "wall-clock independence" do
    test "the expiry bound is monotonic, so an NTP step cannot extend it" do
      # The lease's own expires_at is wall-clock and here deliberately absurd;
      # bounded staleness must ignore it and use its own monotonic deadline.
      absurd = %Lease{lease() | expires_at: System.system_time(:millisecond) + 10_000_000}
      ownership = Ownership.held(absurd, 1)
      Process.sleep(20)

      assert {:error, {:lease_expired, _}} = Ownership.check(ownership, :bounded)
    end
  end
end
