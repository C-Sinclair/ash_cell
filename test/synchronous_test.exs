defmodule AshCell.SynchronousTest do
  @moduledoc """
  A cell's connection runs `synchronous: :full` unless its repo chose another level.

  Under `:normal` a power cut loses acknowledged commits. `scripts/power_loss/run.sh`
  shows that against a real block device; this test only checks the pragma a cell
  ends up with. See ADR-20.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "synchronous_#{System.unique_integer([:positive])}")
    config = Application.get_env(:ash_cell, AshCell.TestRepo)

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, migrations_path: AshCell.TestMigrations.path(:test)}
    )

    on_exit(fn ->
      Application.put_env(:ash_cell, AshCell.TestRepo, config)
      File.rm_rf!(dir)
    end)

    {:ok, config: config}
  end

  # SQLite reports the level as a number: 1 is NORMAL, 2 is FULL.
  defp synchronous(cell) do
    AshCell.with_tenant(cell, fn ->
      %{rows: [[level]]} = AshCell.TestRepo.query!("PRAGMA synchronous")
      level
    end)
  end

  test "a cell runs synchronous=FULL by default" do
    assert synchronous("sync_default") == 2
  end

  test "a level set in the repo's config wins over the default", %{config: config} do
    Application.put_env(
      :ash_cell,
      AshCell.TestRepo,
      Keyword.put(config, :synchronous, :normal)
    )

    assert synchronous("sync_configured") == 1
  end
end
