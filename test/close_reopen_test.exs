defmodule AshCell.CloseReopenTest do
  @moduledoc """
  Closing a cell and immediately reopening it.

  This is a regression test for a flake, and worth saying so plainly: the original
  failure was `AshCell.Manager.ensure_started/1` returning a pid that was already
  dead, so the caller got a `no process` exit from a GenServer it never knew about,
  nowhere near the code that closed the cell. It appeared roughly one run in eight
  of the full suite, never in isolation, and never reproducibly at a fixed seed --
  it is timing, not ordering.

  The cause is that a cell registers through a `:via` tuple, so the registry drops
  its entry when it processes the process's DOWN message, asynchronously.
  `Manager.close/2` has already returned by then.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "reopen_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  test "a reopened cell is alive and answers, over many cycles" do
    # Repeated because once is not evidence for a race. The assertion is on the
    # thing that actually broke: a call to the returned pid.
    for i <- 1..200 do
      cell = "reopen_#{i}"

      AshCell.with_tenant(cell, fn ->
        AshCell.Test.TenantPatient.create!("Row #{i}", tenant: cell)
      end)

      AshCell.close(cell)

      assert {:ok, pid} = AshCell.Manager.ensure_started(cell)
      assert Process.alive?(pid), "ensure_started returned a dead pid on cycle #{i}"
      assert AshCell.Cell.info(pid).schema_version == 3
    end
  end

  test "the same cell closed and reopened repeatedly keeps its rows" do
    AshCell.with_tenant("churn", fn ->
      AshCell.Test.TenantPatient.create!("Survivor", tenant: "churn")
    end)

    for _ <- 1..100 do
      AshCell.close("churn")
      assert {:ok, pid} = AshCell.Manager.ensure_started("churn")
      assert Process.alive?(pid)
    end

    assert ["Survivor"] =
             AshCell.with_tenant("churn", fn ->
               AshCell.Test.TenantPatient
               |> Ash.Query.set_tenant("churn")
               |> Ash.read!()
               |> Enum.map(& &1.name)
             end)
  end

  test "a closed cell leaves no registry entry behind" do
    # The window stated directly: after close/1 returns, nothing should still
    # resolve the cell to a process.
    for i <- 1..200 do
      cell = "gone_#{i}"
      AshCell.with_tenant(cell, fn -> :ok end)
      AshCell.close(cell)

      assert AshCell.Registry.lookup(cell) == :error,
             "registry still resolved #{cell} after close on cycle #{i}"
    end
  end
end
