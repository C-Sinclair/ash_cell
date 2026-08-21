defmodule AshCell.NonTenantedTest do
  @moduledoc """
  Resources that are not cells, alongside ones that are.

  `AshCell.Resource` refuses anything but `strategy :context`, so a shared table is
  a plain `AshSqlite.DataLayer` resource. The question this pins down is whether it
  stays plain: an ambient cell binding is exactly the kind of thing that leaks, and
  a shared row written into one tenant's database would be both wrong and invisible.

  It does not leak, and the reason is narrow enough to be worth stating. Ecto keys
  the dynamic binding as `{repo_module, :dynamic_repo}`, so binding a cell affects
  one module only. A non-tenanted resource on its *own* repo module is immune by
  construction; one sharing the cells' module is not, which is why they should not
  share it.
  """
  use ExUnit.Case, async: false

  alias AshCell.Test.{BoundPatient, Note, Patient}

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_nt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(__DIR__, "../tmp"))

    start_supervised!(AshCell.TestGlobalRepo)

    Ecto.Adapters.SQL.query!(AshCell.TestGlobalRepo, "DROP TABLE IF EXISTS notes", [])

    Ecto.Adapters.SQL.query!(
      AshCell.TestGlobalRepo,
      "CREATE TABLE notes (id TEXT PRIMARY KEY, body TEXT NOT NULL)",
      []
    )

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations, max_resident: 8}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  describe "transactions on a resource that is not a cell" do
    test "the sqlite option is enough on its own, with no extension" do
      assert Ash.DataLayer.data_layer_can?(Note, :transact)
    end

    test "a failing multi-step action rolls back" do
      assert {:error, _} = Note.create_then_fail("Rolled Back")
      assert {:ok, []} = Note.read()
    end

    test "a succeeding one commits" do
      assert {:ok, _} = Note.create("Committed")
      assert {:ok, [%{body: "Committed"}]} = Note.read()
    end

    test "and it needs no binding of any kind" do
      refute AshCell.bound_tenant()
      assert {:ok, _} = Note.create("Unbound")
      assert {:ok, [_]} = Note.read()
    end
  end

  describe "a cell binding does not reach another repo module" do
    test "a shared write issued while bound to a cell lands in the shared database" do
      AshCell.with_tenant("acme", fn ->
        {:ok, _} = Note.create("Written While Bound To Acme")
      end)

      # Read it back with nothing bound: if the binding had leaked, the row would
      # be inside acme's cell file and this would come back empty.
      refute AshCell.bound_tenant()
      assert {:ok, [%{body: "Written While Bound To Acme"}]} = Note.read()
    end

    test "the cell's own database is untouched by it" do
      AshCell.with_tenant("acme", fn -> {:ok, _} = Note.create("Shared Row") end)

      assert {:ok, []} = BoundPatient.read(tenant: "acme")
    end

    test "a shared transaction and a cell transaction are separate transactions" do
      # Both open, neither is the other's. This is the cross-data-layer version of
      # the cross-cell boundary: two connections, so two commits, so not atomic
      # together. Rolling the cell back leaves the shared row behind.
      assert {:error, :abandon} =
               AshCell.transaction("acme", fn ->
                 {:ok, _} = BoundPatient.create("Cell Row", tenant: "acme")
                 {:ok, _} = Note.create("Shared Row")
                 AshCell.rollback(:abandon)
               end)

      assert {:ok, []} = BoundPatient.read(tenant: "acme")
      assert {:ok, [%{body: "Shared Row"}]} = Note.read()
    end
  end

  describe "the trap: sharing the cells' repo module" do
    test "a non-tenanted resource on the cells' repo follows whatever is bound" do
      # AshCell.Test.Patient declares `repo AshCell.TestRepo`, the same module the
      # cells use, so the binding it inherits decides where its rows go. Nothing
      # raises: this is the shape to avoid, not a bug to be caught at runtime.
      AshCell.with_tenant("acme", fn -> {:ok, _} = Patient.create("Ends Up In Acme") end)

      in_acme =
        AshCell.with_tenant("acme", fn ->
          %{rows: rows} =
            Ecto.Adapters.SQL.query!(
              AshCell.TestRepo.get_dynamic_repo(),
              "SELECT name FROM patients",
              []
            )

          List.flatten(rows)
        end)

      assert in_acme == ["Ends Up In Acme"]

      in_globex =
        AshCell.with_tenant("globex", fn ->
          %{rows: rows} =
            Ecto.Adapters.SQL.query!(
              AshCell.TestRepo.get_dynamic_repo(),
              "SELECT name FROM patients",
              []
            )

          List.flatten(rows)
        end)

      assert in_globex == []
    end
  end
end
