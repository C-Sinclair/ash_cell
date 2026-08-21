defmodule AshCell.MigrationTest do
  @moduledoc """
  Lazy per-cell migration, and the operational properties that make it safe
  rather than merely convenient.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshCell.Test.TenantPatient

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_mig_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp start_fleet(dir, migrator) do
    start_supervised!({AshCell, repo: AshCell.TestRepo, dir: dir, migrator: migrator})
  end

  describe "applying migrations" do
    test "a fresh cell is migrated to the target version before serving", %{dir: dir} do
      start_fleet(dir, AshCell.TestMigrations)

      {:ok, pid} = AshCell.Manager.ensure_started("acme")
      info = AshCell.Cell.info(pid)

      assert info.schema_version == AshCell.TestMigrations.target_version()
      assert info.schema_version == 3
    end

    test "migrations run in version order and are recorded in user_version", %{dir: dir} do
      start_fleet(dir, AshCell.TestMigrations)

      AshCell.with_tenant("acme", fn ->
        {:ok, pid} = AshCell.Manager.ensure_started("acme")
        repo_pid = AshCell.Cell.repo_pid(pid)

        assert AshCell.Migrator.current_version(repo_pid) == 3

        # Version 3 added a column to the table version 1 created, so ordering held.
        assert %{rows: _} =
                 Ecto.Adapters.SQL.query!(repo_pid, "SELECT mrn FROM tenant_patients", [])
      end)
    end

    test "reopening an already-migrated cell applies nothing and keeps the data", %{dir: dir} do
      start_fleet(dir, AshCell.TestMigrations)

      AshCell.with_tenant("acme", fn -> TenantPatient.create!("Survivor", tenant: "acme") end)
      AshCell.close("acme")

      {:ok, pid} = AshCell.Manager.ensure_started("acme")
      assert AshCell.Cell.info(pid).schema_version == 3

      assert ["Survivor"] =
               AshCell.with_tenant("acme", fn ->
                 TenantPatient
                 |> Ash.Query.set_tenant("acme")
                 |> Ash.read!()
                 |> Enum.map(& &1.name)
               end)
    end

    test "a cell created at an old version is brought forward, not recreated", %{dir: dir} do
      # Start on a truncated migration set, then restart the fleet on the full one:
      # the same file has to be upgraded in place, with its rows intact.
      start_supervised!(
        {AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.PartialMigrations},
        id: :partial
      )

      AshCell.with_tenant("acme", fn -> TenantPatient.create!("Early Row", tenant: "acme") end)

      {:ok, pid} = AshCell.Manager.ensure_started("acme")
      assert AshCell.Cell.info(pid).schema_version == 1

      stop_supervised!(:partial)
      start_fleet(dir, AshCell.TestMigrations)

      {:ok, pid} = AshCell.Manager.ensure_started("acme")
      assert AshCell.Cell.info(pid).schema_version == 3

      assert ["Early Row"] =
               AshCell.with_tenant("acme", fn ->
                 TenantPatient
                 |> Ash.Query.set_tenant("acme")
                 |> Ash.read!()
                 |> Enum.map(& &1.name)
               end)
    end
  end

  describe "failing closed" do
    test "a cell whose migration fails does not start", %{dir: dir} do
      start_fleet(dir, AshCell.FailingMigrations)

      assert {:error, _reason} = AshCell.Manager.ensure_started("doomed")
      refute "doomed" in AshCell.resident_cells()
    end

    test "the failure is recorded so an unattended outage is visible", %{dir: dir} do
      start_fleet(dir, AshCell.FailingMigrations)

      AshCell.Manager.ensure_started("doomed")

      quarantined = AshCell.Manager.quarantined()
      assert Map.has_key?(quarantined, "doomed")
    end

    test "a failed migration leaves earlier versions applied, not half-applied", %{dir: dir} do
      start_fleet(dir, AshCell.FailingMigrations)
      AshCell.Manager.ensure_started("doomed")

      # Version 1 committed; version 2 rolled back. The cell is at 1, so a fixed
      # deploy resumes from there rather than re-running what already succeeded.
      {:ok, repo_pid} =
        AshCell.TestRepo.start_link(
          name: nil,
          database: Path.join(dir, "doomed.db"),
          pool_size: 1
        )

      assert AshCell.Migrator.current_version(repo_pid) == 1
    end

    test "quarantine clears once the tenant activates successfully", %{dir: dir} do
      start_fleet(dir, AshCell.FailingMigrations)
      AshCell.Manager.ensure_started("doomed")
      assert Map.has_key?(AshCell.Manager.quarantined(), "doomed")

      assert :ok = AshCell.Manager.release("doomed")
      refute Map.has_key?(AshCell.Manager.quarantined(), "doomed")
    end
  end

  describe "eager fleet migration" do
    test "migrates every named tenant and reports each version", %{dir: dir} do
      start_fleet(dir, AshCell.TestMigrations)

      results = AshCell.Manager.migrate_all(["a", "b", "c"])

      assert [{"a", {:ok, 3}}, {"b", {:ok, 3}}, {"c", {:ok, 3}}] = results
      # Cells are closed afterwards so a deploy-time sweep does not leave the whole
      # fleet resident.
      assert AshCell.resident_cells() == []
    end

    test "reports failures per tenant rather than aborting the sweep", %{dir: dir} do
      start_fleet(dir, AshCell.FailingMigrations)

      results = AshCell.Manager.migrate_all(["a", "b"])

      assert Enum.all?(results, fn {_tenant, result} -> match?({:error, _}, result) end)
      assert length(results) == 2
    end
  end
end
