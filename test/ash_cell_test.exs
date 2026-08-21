defmodule AshCellTest do
  @moduledoc """
  End-to-end behaviour of the cell runtime, using a resource that declares
  `multitenancy do strategy :context end` — which only compiles because of the
  ash_sqlite fork change.
  """
  use ExUnit.Case, async: false

  alias AshCell.Test.TenantPatient

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_rt_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, max_resident: 3, migrator: &AshCell.TestSchema.run/1}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp create(tenant, name) do
    AshCell.with_tenant(tenant, fn -> TenantPatient.create!(name, tenant: tenant) end)
  end

  defp names(tenant) do
    AshCell.with_tenant(tenant, fn ->
      TenantPatient
      |> Ash.Query.set_tenant(tenant)
      |> Ash.read!()
      |> Enum.map(& &1.name)
      |> Enum.sort()
    end)
  end

  describe "tenant isolation" do
    test "each tenant sees only its own records" do
      create("acme", "Acme One")
      create("acme", "Acme Two")
      create("globex", "Globex One")

      assert ["Acme One", "Acme Two"] = names("acme")
      assert ["Globex One"] = names("globex")
    end

    test "isolation is a separate file, not a filter" do
      create("acme", "Acme Only")
      create("globex", "Globex Only")
      AshCell.checkpoint("acme")
      AshCell.checkpoint("globex")

      assert file_contains?(AshCell.path_for("acme"), "Acme Only")
      refute file_contains?(AshCell.path_for("acme"), "Globex Only")
      refute file_contains?(AshCell.path_for("globex"), "Acme Only")
    end

    test "a tenant with no writes still gets its own empty database" do
      create("acme", "Acme Only")
      assert [] = names("fresh_tenant")
      assert File.exists?(AshCell.path_for("fresh_tenant"))
    end
  end

  describe "deletion" do
    test "removes the tenant's bytes from disk entirely" do
      create("doomed", "Sensitive Record")
      AshCell.checkpoint("doomed")
      path = AshCell.path_for("doomed")
      assert file_contains?(path, "Sensitive Record")

      {:ok, removed} = AshCell.delete("doomed")

      assert path in removed
      refute File.exists?(path)
      refute "doomed" in AshCell.resident_cells()
    end

    test "deleting one tenant leaves others untouched" do
      create("keeper", "Kept Record")
      create("doomed", "Deleted Record")

      {:ok, _} = AshCell.delete("doomed")

      assert ["Kept Record"] = names("keeper")
    end
  end

  describe "residency" do
    test "cells start on demand and appear in the fleet" do
      assert [] = AshCell.resident_cells()

      create("acme", "One")

      assert ["acme"] = AshCell.resident_cells()
      assert [%{cell_key: "acme", queries: queries, bytes: bytes}] = AshCell.fleet()
      assert queries > 0
      assert bytes > 0
    end

    test "evicts the least recently used cell past max_resident, without data loss" do
      for tenant <- ["t1", "t2", "t3"], do: create(tenant, "row for #{tenant}")
      assert length(AshCell.resident_cells()) == 3

      create("t4", "row for t4")

      # Bounded residency, and the evicted tenant's data is still there when it
      # is next asked for — eviction closes a connection, it does not lose rows.
      assert length(AshCell.resident_cells()) <= 3
      assert ["row for t1"] = names("t1")
    end

    test "closing a cell keeps the data" do
      create("acme", "Persisted")
      :ok = AshCell.close("acme")

      refute "acme" in AshCell.resident_cells()
      assert ["Persisted"] = names("acme")
    end
  end

  describe "process binding" do
    test "the binding is restored after with_tenant returns" do
      create("acme", "One")
      assert AshCell.TestRepo.get_dynamic_repo() == AshCell.TestRepo
    end

    test "nesting restores the outer tenant" do
      create("outer", "Outer Row")
      create("inner", "Inner Row")

      result =
        AshCell.with_tenant("outer", fn ->
          inner = AshCell.with_tenant("inner", fn -> read_names("inner") end)
          {inner, read_names("outer")}
        end)

      assert {["Inner Row"], ["Outer Row"]} = result
    end
  end

  defp read_names(tenant) do
    TenantPatient
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read!()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp file_contains?(path, string) do
    case File.read(path) do
      {:ok, contents} -> String.contains?(contents, string)
      _ -> false
    end
  end
end
