defmodule AshCell.RepoTest do
  @moduledoc """
  A cell repo started from its own place in the supervision tree, and configured the
  way `AshSqlite.MultiTenancy` is: `tenants:` on the repo, and the cell key handed to
  `init/2` as `:tenant`.
  """
  use ExUnit.Case, async: false

  alias AshCell.Test.BoundPatient
  alias AshCell.TestRepo

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_repo_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "starting the repo starts the fleet from its tenants: option", %{dir: dir} do
    start_supervised!(
      {TestRepo, tenants: [dir: dir, migrations_path: AshCell.TestMigrations.path(:test)]}
    )

    {:ok, _} = BoundPatient.create("Ada", tenant: "acme")

    assert {:ok, [%{name: "Ada"}]} = BoundPatient.read(tenant: "acme")
    assert File.exists?(Path.join(dir, "acme.db"))
  end

  test "tenants: is read from the repo's application env too", %{dir: dir} do
    previous = Application.get_env(:ash_cell, TestRepo)

    Application.put_env(
      :ash_cell,
      TestRepo,
      Keyword.put(previous, :tenants,
        dir: dir,
        migrations_path: AshCell.TestMigrations.path(:test)
      )
    )

    on_exit(fn -> Application.put_env(:ash_cell, TestRepo, previous) end)

    start_supervised!(TestRepo)

    assert {:ok, _} = BoundPatient.create("Ada", tenant: "acme")
  end

  test "a cell repo with no tenants: refuses to start, naming the key" do
    assert_raise ArgumentError, ~r/no `tenants:` configuration/, fn ->
      TestRepo.child_spec([])
    end
  end

  test "init/2 is given the cell key as :tenant", %{dir: dir} do
    test = self()

    Application.put_env(:ash_cell, :test_key_for, fn tenant ->
      send(test, {:init_saw, tenant})
      nil
    end)

    on_exit(fn -> Application.delete_env(:ash_cell, :test_key_for) end)

    start_supervised!(
      {TestRepo, tenants: [dir: dir, migrations_path: AshCell.TestMigrations.path(:test)]}
    )

    {:ok, _} = AshCell.Manager.ensure_started("acme:2026-10")

    assert_received {:init_saw, "acme:2026-10"}
  end

  defp record_init_tenants do
    test = self()

    Application.put_env(:ash_cell, :test_key_for, fn tenant ->
      send(test, {:init_saw, tenant})
      nil
    end)

    on_exit(fn -> Application.delete_env(:ash_cell, :test_key_for) end)
  end

  test "AshCell itself runs init/2 only for cells", %{dir: dir} do
    # init/2 derives a cell's key from config[:tenant]. `AshCell.ReadCache` used to
    # read the telemetry prefix through `repo.config/0`, which runs init/2 with no
    # cell. With no migrations there is nothing else to call it.
    record_init_tenants()

    start_supervised!({TestRepo, tenants: [dir: dir]})
    {:ok, _} = AshCell.Manager.ensure_started("acme")

    assert_received {:init_saw, "acme"}
    refute_received {:init_saw, nil}
  end

  test "Ecto.Migrator runs init/2 with no :tenant too, so a key function must allow nil",
       %{dir: dir} do
    # `Ecto.Migrator` reads `repo.config/0` itself, as it does under
    # AshSqlite.MultiTenancy. The cell still opens, under the key its own init/2 set.
    record_init_tenants()

    start_supervised!(
      {TestRepo, tenants: [dir: dir, migrations_path: AshCell.TestMigrations.path(:test)]}
    )

    assert {:ok, _} = BoundPatient.create("Ada", tenant: "acme")
    assert_received {:init_saw, "acme"}
    assert_received {:init_saw, nil}
  end

  test "init/2 keeps AshCell's options away from the adapter" do
    {:ok, config} =
      TestRepo.init(:runtime, database: "x.db", tenant: "acme", tenants: [], encrypted?: false)

    refute Keyword.has_key?(config, :tenant)
    refute Keyword.has_key?(config, :tenants)
    refute Keyword.has_key?(config, :encrypted?)
    assert config[:database] == "x.db"
  end
end
