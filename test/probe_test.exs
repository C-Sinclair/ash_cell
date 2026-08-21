defmodule AshCell.ProbeTest do
  @moduledoc """
  The gating question for the whole design: can an Ash query be routed to a
  *specific* per-tenant SQLite database at runtime?

  Two candidate mechanisms, and this pins down exactly what each one does:

    1. Query/changeset context override (`%{data_layer: %{repo: ...}}`).
       AshSqlite consults it before the DSL-declared repo.
    2. Ecto's dynamic repo binding (`Repo.put_dynamic_repo/1`).

  Both read (`repo.all/2`) and write (`repo.insert_all/3`) invoke the resolved
  repo as a *module*, so the override can only ever select a module. Binding an
  *instance* is Ecto's job, and Ecto binds per-process.
  """
  use ExUnit.Case, async: false

  alias AshCell.Test.Patient
  alias AshCell.TestRepo

  @moduletag :probe

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_probe_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    tenants =
      for name <- [:acme, :globex], into: %{} do
        path = Path.join(dir, "#{name}.db")
        {:ok, pid} = TestRepo.start_link(name: nil, database: path, pool_size: 1)

        TestRepo.put_dynamic_repo(pid)

        Ecto.Adapters.SQL.query!(pid, """
        CREATE TABLE IF NOT EXISTS patients (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL
        )
        """)

        {name, %{pid: pid, path: path}}
      end

    TestRepo.put_dynamic_repo(nil)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, tenants: tenants, dir: dir}
  end

  describe "binding a tenant with put_dynamic_repo/1" do
    test "writes and reads land in the bound tenant only", %{tenants: t} do
      in_cell(t.acme, fn -> Patient.create!("Acme Patient") end)
      in_cell(t.globex, fn -> Patient.create!("Globex Patient") end)

      assert ["Acme Patient"] = in_cell(t.acme, &names/0)
      assert ["Globex Patient"] = in_cell(t.globex, &names/0)
    end

    test "separation is physical, not a filter", %{tenants: t} do
      in_cell(t.acme, fn -> Patient.create!("Only In Acme") end)

      # Read the files directly, bypassing Ash entirely.
      assert [["Only In Acme"]] = raw_names(t.acme.pid)
      assert [] = raw_names(t.globex.pid)
    end

    test "a deep relationship-free read of many rows stays in one database", %{tenants: t} do
      in_cell(t.acme, fn ->
        for i <- 1..500, do: Patient.create!("Patient #{i}")
      end)

      assert 500 = length(in_cell(t.acme, &names/0))
      assert [] = in_cell(t.globex, &names/0)
    end
  end

  describe "the context repo override" do
    test "selects a repo MODULE, and cannot carry an instance pid", %{tenants: t} do
      # Documents the boundary precisely: AshSqlite resolves the override and
      # then calls it as a module (`repo.all/2`, `repo.insert_all/3`), so a pid
      # raises rather than routing. This is why AshCell binds with Ecto's
      # dynamic repo rather than passing pids through the context.
      error =
        assert_raise Ash.Error.Unknown, fn ->
          Patient
          |> Ash.Query.set_context(%{data_layer: %{repo: t.acme.pid}})
          |> Ash.read!()
        end

      assert Exception.message(error) =~
               "Modules (the first argument of apply) must always be an atom"
    end

    test "selecting the declared module explicitly is accepted", %{tenants: t} do
      # A module override is the supported shape, and it composes with the
      # process binding: the module resolves, Ecto routes it to the bound pid.
      in_cell(t.acme, fn ->
        Patient.create!("Module Override")

        rows =
          Patient
          |> Ash.Query.set_context(%{data_layer: %{repo: AshCell.TestRepo}})
          |> Ash.read!()
          |> Enum.map(& &1.name)

        assert ["Module Override"] = rows
      end)
    end
  end

  describe "process boundaries" do
    test "the binding does NOT survive a Task, and must be re-established", %{tenants: t} do
      in_cell(t.acme, fn -> Patient.create!("Across A Task") end)

      unbound =
        Task.async(fn ->
          try do
            {:ok, names()}
          rescue
            e -> {:raised, e.__struct__}
          end
        end)
        |> Task.await()

      # Whatever it does, it must not silently read the wrong tenant.
      case unbound do
        {:ok, rows} -> refute rows == ["Across A Task"]
        {:raised, _} -> :ok
      end

      # Re-binding inside the task is the sanctioned pattern, and it works.
      rebound =
        Task.async(fn -> in_cell(t.acme, &names/0) end)
        |> Task.await()

      assert ["Across A Task"] = rebound
    end
  end

  defp in_cell(%{pid: pid}, fun) do
    previous = TestRepo.get_dynamic_repo()
    TestRepo.put_dynamic_repo(pid)

    try do
      fun.()
    after
      TestRepo.put_dynamic_repo(previous)
    end
  end

  defp names do
    Patient
    |> Ash.read!()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp raw_names(pid) do
    %{rows: rows} = Ecto.Adapters.SQL.query!(pid, "SELECT name FROM patients", [])
    rows
  end
end
