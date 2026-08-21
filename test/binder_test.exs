defmodule AshCell.BinderTest do
  @moduledoc """
  What `AshCell.Resource` buys, and where it stops.

  The claim under test is narrow and worth pinning down: with the extension on a
  resource, no caller anywhere has to bind, including callers that *cannot* — an
  aggregate, an atomic UPDATE, a process nobody wrapped. The counter-claim matters
  just as much: a statement that arrives without a tenant must not run.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshCell.Test.{BoundPatient, TenantPatient}

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_binder_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations, max_resident: 8}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  describe "no caller has to bind" do
    test "a process nobody wrapped reads and writes the right cell" do
      # A bare Task: nothing was inherited, and no with_tenant/2 appears anywhere
      # in this block. Previously this raised "repo not started".
      result =
        Task.async(fn ->
          {:ok, _} = BoundPatient.create("Acme Row", tenant: "acme")
          {:ok, _} = BoundPatient.create("Globex Row", tenant: "globex")

          %{
            acme: Ash.read!(BoundPatient, tenant: "acme") |> Enum.map(& &1.name),
            globex: Ash.read!(BoundPatient, tenant: "globex") |> Enum.map(& &1.name)
          }
        end)
        |> Task.await(10_000)

      assert %{acme: ["Acme Row"], globex: ["Globex Row"]} = result
    end

    test "an aggregate binds, though it never enters Ash.Actions.Read" do
      {:ok, _} = BoundPatient.create("One", tenant: "acme")
      {:ok, _} = BoundPatient.create("Two", tenant: "acme")
      {:ok, _} = BoundPatient.create("Elsewhere", tenant: "globex")

      assert 2 == Ash.count!(BoundPatient, tenant: "acme")
      assert 1 == Ash.count!(BoundPatient, tenant: "globex")
    end

    test "an atomic update binds, though Ash skips change/3 to build one statement" do
      {:ok, row} = BoundPatient.create("Before", tenant: "acme")
      {:ok, _} = BoundPatient.create("Before", tenant: "globex")

      # require_atomic? true on :rename, so this either goes through
      # update_query/4 as a single UPDATE or it fails.
      {:ok, renamed} = BoundPatient.rename(row, "After", tenant: "acme")

      assert renamed.name == "After"
      assert ["After"] = Ash.read!(BoundPatient, tenant: "acme") |> Enum.map(& &1.name)
      assert ["Before"] = Ash.read!(BoundPatient, tenant: "globex") |> Enum.map(& &1.name)
    end

    test "a bulk update through the atomic strategy binds" do
      {:ok, _} = BoundPatient.create("Bulk", tenant: "acme")
      {:ok, _} = BoundPatient.create("Bulk", tenant: "globex")

      result =
        BoundPatient
        |> Ash.Query.filter(name == "Bulk")
        |> Ash.bulk_update(:rename, %{name: "Renamed"},
          strategy: [:atomic],
          tenant: "acme",
          return_errors?: true
        )

      assert result.status == :success
      assert ["Renamed"] = Ash.read!(BoundPatient, tenant: "acme") |> Enum.map(& &1.name)
      assert ["Bulk"] = Ash.read!(BoundPatient, tenant: "globex") |> Enum.map(& &1.name)
    end

    test "a bulk create binds" do
      Ash.bulk_create!([%{name: "A"}, %{name: "B"}], BoundPatient, :create, tenant: "acme")

      assert ["A", "B"] =
               Ash.read!(BoundPatient, tenant: "acme") |> Enum.map(& &1.name) |> Enum.sort()

      assert [] = Ash.read!(BoundPatient, tenant: "globex")
    end
  end

  describe "the binding is released" do
    test "nothing is left bound to the caller afterwards" do
      {:ok, _} = BoundPatient.create("Row", tenant: "acme")
      Ash.read!(BoundPatient, tenant: "acme")

      assert nil == AshCell.bound_cell()
    end

    test "an outer binding survives an action on a different tenant" do
      {:ok, _} = BoundPatient.create("Acme Row", tenant: "acme")
      {:ok, _} = BoundPatient.create("Globex Row", tenant: "globex")

      assert {["Globex Row"], "acme"} =
               AshCell.with_tenant("acme", fn ->
                 rows = Ash.read!(BoundPatient, tenant: "globex") |> Enum.map(& &1.name)
                 {rows, AshCell.bound_cell()}
               end)
    end

    test "a failed action does not leak a hold on the cell" do
      {:ok, _} = BoundPatient.create("Row", tenant: "acme")

      assert {:error, _} = BoundPatient.create(nil, tenant: "acme")
      assert nil == AshCell.bound_cell()

      # A leaked bind count would leave the cell looking permanently busy, and a
      # drain would never see it as quiescent.
      assert {:ok, _} = AshCell.Drain.run(timeout: 500)
    end
  end

  describe "it fails closed" do
    test "a tenanted statement with no tenant is refused, not run against the default" do
      assert {:error, _} = Ash.read(BoundPatient)
    end

    test "the error names the tenant when its cell cannot be bound" do
      error = %AshCell.CellUnavailableError{cell_key: "acme", reason: :cell_closing}

      assert Exception.message(error) =~ "acme"
      assert Exception.message(error) =~ "was not run"
    end
  end

  describe "it changes who binds, not where rows go" do
    test "a row written through the extension is read by the unextended resource" do
      {:ok, _} = BoundPatient.create("Shared Table", tenant: "acme")

      assert ["Shared Table"] =
               AshCell.with_tenant("acme", fn ->
                 TenantPatient |> Ash.read!(tenant: "acme") |> Enum.map(& &1.name)
               end)
    end
  end
end
