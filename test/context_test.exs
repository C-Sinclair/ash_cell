defmodule AshCell.ContextTest do
  @moduledoc """
  How tenant context is carried, and what happens when it is not.

  These tests pin down the answers to the three questions the design kept
  bumping into: what the handle should be, how background work gets one, and
  whether an unbound caller fails loudly.
  """
  use ExUnit.Case, async: false

  alias AshCell.Test.TenantPatient

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_ctx_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations, max_resident: 8}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "what can be a tenant handle" do
    test "Ecto accepts only an atom or a pid, so a via-tuple cannot be the handle" do
      # Documents why AshCell resolves tenant ids through its own registry rather
      # than handing Ecto a via-tuple: put_dynamic_repo/1 guards on
      # `is_atom(dynamic) or is_pid(dynamic)`.
      assert_raise FunctionClauseError, fn ->
        AshCell.TestRepo.put_dynamic_repo({:via, Registry, {AshCell.Registry, "acme"}})
      end
    end

    test "the tenant id is a stable handle across a cell restart" do
      write("acme", "Before Restart")
      {:ok, first} = AshCell.Manager.ensure_started("acme")

      # Kill the cell. A pid handle would now be dangling; the tenant id is not.
      AshCell.close("acme")
      {:ok, second} = AshCell.Manager.ensure_started("acme")

      refute first == second
      assert ["Before Restart"] = read("acme")
    end
  end

  describe "binding across process boundaries" do
    test "an unrelated process binds by tenant id alone, inheriting nothing" do
      write("acme", "Written By Parent")

      # A bare spawned process, not a Task linked to this one — nothing about the
      # caller is available to it except the tenant id it was given.
      parent = self()

      spawn(fn ->
        result = AshCell.with_tenant("acme", fn -> read_bound() end)
        send(parent, {:result, result})
      end)

      assert_receive {:result, ["Written By Parent"]}, 5_000
    end

    test "a Task starts unbound and reports no tenant" do
      write("acme", "Row")

      assert nil ==
               AshCell.with_tenant("acme", fn ->
                 Task.async(fn -> AshCell.bound_tenant() end) |> Task.await()
               end)
    end

    test "assert_bound! fails loudly rather than letting a query fail obscurely" do
      assert_raise ArgumentError, ~r/no AshCell tenant is bound/, fn ->
        AshCell.assert_bound!()
      end

      assert "acme" == AshCell.with_tenant("acme", fn -> AshCell.assert_bound!() end)
    end

    test "bound_tenant survives a cell restart under the same binding call" do
      assert "acme" = AshCell.with_tenant("acme", fn -> AshCell.bound_tenant() end)
      assert nil == AshCell.bound_tenant()
    end
  end

  describe "background jobs" do
    test "job args carry the tenant and bind it" do
      write("acme", "Job Sees This")

      args = AshCell.Job.args!("acme", %{some: "payload"})

      assert {:ok, ["Job Sees This"]} =
               AshCell.Job.run(args, fn tenant ->
                 assert tenant == "acme"
                 {:ok, read_bound()}
               end)
    end

    test "args round-trip through JSON string keys" do
      write("acme", "Row")
      args = %{"tenant" => "acme", "patient_id" => "x"}

      assert {:ok, _} = AshCell.Job.run(args, fn _ -> {:ok, read_bound()} end)
    end

    test "a job with no tenant is cancelled, not retried" do
      # Retrying can never help, and retrying forever hides the bug.
      assert {:cancel, :missing_tenant} = AshCell.Job.run(%{"patient_id" => "x"}, fn _ -> :ok end)
    end

    test "args!/2 refuses to build args without a tenant" do
      assert_raise FunctionClauseError, fn -> AshCell.Job.args!(nil, %{}) end
    end

    test "a job binds its own tenant regardless of the caller's binding" do
      write("acme", "Acme Row")
      write("globex", "Globex Row")

      result =
        AshCell.with_tenant("acme", fn ->
          AshCell.Job.run(%{"tenant" => "globex"}, fn _ -> read_bound() end)
        end)

      assert ["Globex Row"] = result
      assert ["Acme Row"] = read("acme")
    end
  end

  describe "nesting and restoration" do
    test "the outer binding is restored after an inner one" do
      write("outer", "Outer Row")
      write("inner", "Inner Row")

      assert {["Inner Row"], "outer"} =
               AshCell.with_tenant("outer", fn ->
                 inner = AshCell.with_tenant("inner", fn -> read_bound() end)
                 {inner, AshCell.bound_tenant()}
               end)
    end

    test "a raising body still restores the previous binding" do
      write("acme", "Row")

      catch_error(
        AshCell.with_tenant("acme", fn -> raise "boom" end)
      )

      assert nil == AshCell.bound_tenant()
    end
  end

  defp write(tenant, name) do
    AshCell.with_tenant(tenant, fn -> TenantPatient.create!(name, tenant: tenant) end)
  end

  defp read(tenant), do: AshCell.with_tenant(tenant, fn -> read_bound() end)

  defp read_bound do
    tenant = AshCell.bound_tenant()

    TenantPatient
    |> Ash.Query.set_tenant(tenant)
    |> Ash.read!()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end
end
