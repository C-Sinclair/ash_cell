defmodule AshCell.HoldersTest do
  @moduledoc """
  Long-lived holders, and how they change what "idle" means.

  A LiveView holds a tenant for as long as a browser tab is open, but only touches
  it in bursts. Counting transient binds alone reports the cell as idle between
  keystrokes, and a drain would then take it out from under a user who is sitting
  right there looking at it.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_hold_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  describe "holding a tenant" do
    test "a hold keeps the cell non-idle between callbacks" do
      assert :ok = AshCell.bind_held("acme")

      # No bracketing call, and yet the cell is not idle — this is the difference
      # from with_tenant/2.
      assert AshCell.Registry.active_binds("acme") == 1
      assert AshCell.Registry.transient_binds("acme") == 0
    end

    test "re-binding is idempotent, so per-callback binding does not accumulate" do
      for _ <- 1..25, do: AshCell.bind_held("acme")

      assert AshCell.Holders.count("acme") == 1
      assert AshCell.Registry.active_binds("acme") == 1
    end

    test "releasing clears the hold" do
      AshCell.bind_held("acme")
      assert :ok = AshCell.release_held("acme")

      assert AshCell.Registry.active_binds("acme") == 0
      assert AshCell.bound_tenant() == nil
    end
  end

  describe "cleanup" do
    test "a holder that dies is cleaned up without anything having to notice" do
      # The tab-closed case. A leaked holder means a cell that can never drain,
      # so this must not depend on a graceful release.
      parent = self()

      pid =
        spawn(fn ->
          AshCell.bind_held("acme")
          send(parent, :held)
          receive do: (:stop -> :ok)
        end)

      assert_receive :held, 2_000
      assert AshCell.Registry.active_binds("acme") == 1

      send(pid, :stop)
      wait_until(fn -> AshCell.Registry.active_binds("acme") == 0 end)
    end

    test "a holder that crashes is cleaned up too" do
      parent = self()

      spawn(fn ->
        AshCell.bind_held("acme")
        send(parent, :held)
        raise "boom"
      end)

      assert_receive :held, 2_000
      wait_until(fn -> AshCell.Registry.active_binds("acme") == 0 end)
    end
  end

  describe "mixing holders and transient binds" do
    test "both populations count toward whether a cell is busy" do
      AshCell.bind_held("acme")

      AshCell.with_tenant("acme", fn ->
        assert AshCell.Registry.active_binds("acme") == 2
      end)

      # The transient bind is gone; the holder remains.
      assert AshCell.Registry.active_binds("acme") == 1
    end

    test "a held cell never reads as quiescent to a drain" do
      AshCell.bind_held("acme")

      refute AshCell.Drain.await_quiescence("acme", 100)
    end
  end

  describe "stale bindings" do
    test "re-binding after the cell restarts picks up the new instance" do
      AshCell.bind_held("acme")
      {:ok, first} = AshCell.Manager.ensure_started("acme")

      AshCell.close("acme")

      # The old repo pid is dead. Re-binding from the tenant id is what makes a
      # long-lived process survive that; a binding held from mount would not.
      assert :ok = AshCell.bind_held("acme")
      {:ok, second} = AshCell.Manager.ensure_started("acme")

      refute first == second
      assert AshCell.Registry.active_binds("acme") == 1
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end
