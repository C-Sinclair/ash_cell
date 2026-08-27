defmodule AshCell.TransactionTest do
  @moduledoc """
  What transactions do and do not cover for a cell.

  A cell is one SQLite file behind one connection with `pool_size: 1`, which is
  the topology SQLite's single-writer limitation is usually raised against — and
  the reason it does not bite here. There is no second writer to contend with, so
  the only questions left are whether a transaction survives the data layer
  re-resolving a connection per statement, and what happens at the one boundary
  that cannot be transactional: two different cells.
  """
  use ExUnit.Case, async: false

  alias AshCell.Test.{BoundPatient, TenantPatient}

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_tx_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations, max_resident: 8}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  describe "what the extension turns on" do
    test "a resource with AshCell.Resource can transact" do
      assert Ash.DataLayer.data_layer_can?(BoundPatient, :transact)
    end

    test "a plain AshSqlite resource still cannot, so nothing changes upstream" do
      refute Ash.DataLayer.data_layer_can?(TenantPatient, :transact)
    end
  end

  describe "a failing action leaves nothing behind" do
    test "with no caller binding anywhere" do
      assert {:error, _} = BoundPatient.create_then_fail("Rolled Back", tenant: "acme")
      assert {:ok, []} = BoundPatient.read(tenant: "acme")
    end

    test "and a successful one still commits" do
      assert {:ok, _} = BoundPatient.create("Committed", tenant: "acme")
      assert {:ok, [%{name: "Committed"}]} = BoundPatient.read(tenant: "acme")
    end

    test "without touching another tenant's cell" do
      {:ok, _} = BoundPatient.create("Globex Row", tenant: "globex")
      assert {:error, _} = BoundPatient.create_then_fail("Acme Row", tenant: "acme")

      assert {:ok, []} = BoundPatient.read(tenant: "acme")
      assert {:ok, [%{name: "Globex Row"}]} = BoundPatient.read(tenant: "globex")
    end

    test "from a process nobody wrapped" do
      task =
        Task.async(fn ->
          BoundPatient.create_then_fail("From Task", tenant: "acme")
        end)

      assert {:error, _} = Task.await(task)
      assert {:ok, []} = BoundPatient.read(tenant: "acme")
    end
  end

  describe "AshCell.transaction/2" do
    test "makes several actions atomic together" do
      assert {:ok, :both} =
               AshCell.transaction("acme", fn ->
                 {:ok, _} = BoundPatient.create("First", tenant: "acme")
                 {:ok, _} = BoundPatient.create("Second", tenant: "acme")
                 :both
               end)

      assert {:ok, rows} = BoundPatient.read(tenant: "acme")
      assert ["First", "Second"] = rows |> Enum.map(& &1.name) |> Enum.sort()
    end

    test "rollback abandons every action in it" do
      assert {:error, :changed_my_mind} =
               AshCell.transaction("acme", fn ->
                 {:ok, _} = BoundPatient.create("First", tenant: "acme")
                 {:ok, _} = BoundPatient.create("Second", tenant: "acme")
                 AshCell.rollback(:changed_my_mind)
               end)

      assert {:ok, []} = BoundPatient.read(tenant: "acme")
    end

    test "a failing action inside it rolls back the ones before it" do
      assert {:error, _} =
               AshCell.transaction("acme", fn ->
                 {:ok, _} = BoundPatient.create("Before The Failure", tenant: "acme")

                 case BoundPatient.create_then_fail("Fails", tenant: "acme") do
                   {:error, error} -> AshCell.rollback(error)
                 end
               end)

      assert {:ok, []} = BoundPatient.read(tenant: "acme")
    end

    test "reads inside it see its own uncommitted writes" do
      assert {:ok, ["Uncommitted"]} =
               AshCell.transaction("acme", fn ->
                 {:ok, _} = BoundPatient.create("Uncommitted", tenant: "acme")
                 {:ok, rows} = BoundPatient.read(tenant: "acme")
                 Enum.map(rows, & &1.name)
               end)
    end

    test "reports that it is in a transaction, and that it is not afterwards" do
      refute AshCell.in_transaction?()

      {:ok, inside} = AshCell.transaction("acme", fn -> AshCell.in_transaction?() end)

      assert inside
      refute AshCell.in_transaction?()
    end
  end

  describe "the boundary: one cell per transaction" do
    test "a statement for another tenant inside a transaction is refused" do
      error =
        catch_error(
          AshCell.transaction("acme", fn ->
            BoundPatient.create!("Wrong Cell", tenant: "globex")
          end)
        )

      message = Exception.message(error)

      # Asserted on the substance rather than the prose: the tenant that was
      # refused, and the reason a caller has to act on. An earlier version pinned
      # the exact wording and went red when the fork rephrased the message, which
      # is a test failing for something that is not a behaviour.
      assert message =~ "globex"
      assert message =~ ~r/tenant's database/
      assert message =~ "cannot commit across files atomically"
    end

    test "opening a transaction on another tenant inside one is refused" do
      assert_raise ArgumentError, ~r/while one is open on/, fn ->
        AshCell.transaction("acme", fn ->
          AshCell.transaction("globex", fn -> :never end)
        end)
      end
    end

    test "the refusal leaves the outer transaction intact and rollbackable" do
      assert {:error, :aborted} =
               AshCell.transaction("acme", fn ->
                 {:ok, _} = BoundPatient.create("Kept Or Not", tenant: "acme")

                 catch_error(BoundPatient.create!("Wrong Cell", tenant: "globex"))

                 AshCell.rollback(:aborted)
               end)

      assert {:ok, []} = BoundPatient.read(tenant: "acme")
      assert {:ok, []} = BoundPatient.read(tenant: "globex")
    end

    test "sequential transactions on different tenants are fine" do
      {:ok, _} = AshCell.transaction("acme", fn -> BoundPatient.create("A", tenant: "acme") end)

      {:ok, _} =
        AshCell.transaction("globex", fn -> BoundPatient.create("G", tenant: "globex") end)

      assert {:ok, [%{name: "A"}]} = BoundPatient.read(tenant: "acme")
      assert {:ok, [%{name: "G"}]} = BoundPatient.read(tenant: "globex")
    end
  end

  describe "a cell taken mid-transaction" do
    test "aborts the transaction rather than half-applying it" do
      # The drain path's worst case: a cell is taken while an action is partway
      # through. An uncommitted transaction on a closed connection cannot commit,
      # so the work is lost rather than half-kept -- which is the outcome worth
      # having, and the one that was unavailable before transactions.
      test_pid = self()

      task =
        Task.async(fn ->
          try do
            AshCell.transaction("acme", fn ->
              {:ok, _} = BoundPatient.create("First", tenant: "acme")
              send(test_pid, :first_written)
              receive do: (:go -> :ok)
              BoundPatient.create("Second", tenant: "acme")
            end)
          rescue
            error -> {:raised, error.__struct__}
          catch
            :exit, _ -> :exited
          end
        end)

      assert_receive :first_written, 5_000

      AshCell.Manager.close("acme", force: true)
      send(task.pid, :go)

      assert Task.await(task, 10_000) in [{:raised, Ash.Error.Unknown}, :exited]

      # Reopening reads the file, which never received the commit.
      assert {:ok, []} = BoundPatient.read(tenant: "acme")
    end
  end

  describe "what transactions did not break" do
    test "an atomic update is still atomic" do
      {:ok, row} = BoundPatient.create("Before", tenant: "acme")

      assert {:ok, %{name: "After"}} = BoundPatient.rename(row, "After", tenant: "acme")
    end

    test "an aggregate still binds, and is not transactional" do
      {:ok, _} = BoundPatient.create("One", tenant: "acme")
      {:ok, _} = BoundPatient.create("Two", tenant: "acme")

      assert 2 == Ash.count!(BoundPatient, tenant: "acme")
    end

    test "a bulk create still binds" do
      assert %{status: :success} =
               Ash.bulk_create([%{name: "Bulk One"}, %{name: "Bulk Two"}], BoundPatient, :create,
                 tenant: "acme",
                 return_errors?: true
               )

      assert {:ok, rows} = BoundPatient.read(tenant: "acme")
      assert length(rows) == 2
    end
  end
end
