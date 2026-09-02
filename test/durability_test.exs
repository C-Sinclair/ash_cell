defmodule AshCell.DurabilityTest do
  @moduledoc """
  What a cell's connection is actually set to, asserted against a live connection
  rather than against the options we believe we passed.

  Both pragmas here were inherited defaults rather than choices. `journal_mode`
  reached WAL only because `ecto_sqlite3` supplies it, and `synchronous` is still
  `:normal` by omission -- see
  `docs/decisions/ADR-20-choose-a-durability-level.md`, which is open.

  Nothing in this file proves a write survives a power cut. It cannot: killing a
  process leaves the page cache intact, so every assertion here passes under any
  `synchronous` level. It pins the configuration, and the ADR keeps the guarantee.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "durability_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  # Queried against the cell's repo *instance*, because a module call routes through
  # `Ecto.Repo.Registry` rather than the dynamic binding and would ask a repo that
  # was never started. Same reason `AshCell.checkpoint_cell/1` takes the pid.
  defp pragma(tenant, name) do
    {:ok, pid} = AshCell.Manager.ensure_started(AshCell.CellKey.resolve(tenant))
    repo_pid = AshCell.Cell.repo_pid(pid)
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA #{name}", [])
    value
  end

  test "a cell opens in WAL" do
    assert pragma("wal_check", "journal_mode") == "wal"
  end

  test "a cell keeps WAL across a close and reopen" do
    assert pragma("wal_reopen", "journal_mode") == "wal"
    AshCell.close("wal_reopen")
    assert pragma("wal_reopen", "journal_mode") == "wal"
  end

  test "synchronous is NORMAL, the level ADR-20 has not yet closed on" do
    # 1 is NORMAL. Asserted so that a change of durability level is a change to a
    # test that names the ADR, rather than a silent shift in what a COMMIT means.
    assert pragma("sync_check", "synchronous") == 1
  end
end
