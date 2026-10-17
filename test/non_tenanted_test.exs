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
  construction. One sharing the cells' module used to inherit the binding silently;
  AshSqlite now refuses it, at compile time and again on its first statement.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshCell.Test.{BoundPatient, Note}

  setup_all do
    diagnostics = capture_io(:stderr, fn -> Code.compile_quoted(shared_on_cell_repo()) end)
    {:ok, diagnostics: diagnostics}
  end

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
      refute AshCell.bound_cell()
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
      refute AshCell.bound_cell()
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

  describe "sharing the cells' repo module is refused" do
    test "at compile time, by AshSqlite's verifier", %{diagnostics: diagnostics} do
      # A Spark verifier reports through a compile diagnostic, so this fails a
      # `--warnings-as-errors` build, which every CI job here runs.
      assert diagnostics =~ "AshCell.TestRepo is a tenant repo"
      assert diagnostics =~ "strategy :context"
    end

    test "and on its first statement, before a row can land in a cell" do
      # Before upstream's tenant repo, this resource followed whatever the process
      # had bound and its row ended up in acme's file with nothing raising.
      error =
        catch_error(
          AshCell.with_tenant("acme", fn ->
            Ash.create!(AshCell.Test.SharedOnCellRepo, %{name: "Would Be In Acme"})
          end)
        )

      assert Exception.message(error) =~ "is a tenant repo"

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

      assert in_acme == []
    end
  end

  # A non-tenanted resource on the cells' repo module: the shape AshSqlite refuses.
  # Compiled by the test rather than in test/support, because compiling it is the
  # thing under test.
  defp shared_on_cell_repo do
    quote do
      defmodule AshCell.Test.SharedOnCellRepo do
        use Ash.Resource,
          domain: AshCell.Test.SharedOnCellRepoDomain,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "patients"
          repo AshCell.TestRepo
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string, allow_nil?: false, public?: true
        end

        actions do
          defaults [:read, create: [:name]]
        end
      end

      defmodule AshCell.Test.SharedOnCellRepoDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          resource AshCell.Test.SharedOnCellRepo
        end
      end
    end
  end
end
