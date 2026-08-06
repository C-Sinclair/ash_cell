defmodule AshCell.DrainTest do
  @moduledoc """
  Graceful shutdown.

  The deploy problem in one line: a cell deployment moves all its data every time
  it deploys, and a killed node leaves behind leases nobody released and writes
  nobody shipped.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshCell.Test.TenantPatient

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_drain_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations, max_resident: 16}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "sealing" do
    test "a sealed node refuses to take on new cells" do
      assert :ok = AshCell.Manager.seal()
      assert {:error, :draining} = AshCell.Manager.ensure_started("newcomer")
      refute "newcomer" in AshCell.resident_tenants()
    end

    test "an already-resident cell keeps serving while sealed" do
      write("acme", "Mid Flight")
      assert :ok = AshCell.Manager.seal()

      # In-flight work must be able to finish, or draining becomes a hard stop
      # for every request that happened to be running.
      assert ["Mid Flight"] = read("acme")
    end

    test "unsealing lets the node accept cells again" do
      AshCell.Manager.seal()
      assert {:error, :draining} = AshCell.Manager.ensure_started("later")

      AshCell.Manager.unseal()
      assert {:ok, _pid} = AshCell.Manager.ensure_started("later")
    end
  end

  describe "bind counting" do
    test "counts rise and fall with binding" do
      assert AshCell.Registry.active_binds("acme") == 0

      AshCell.with_tenant("acme", fn ->
        assert AshCell.Registry.active_binds("acme") == 1
      end)

      assert AshCell.Registry.active_binds("acme") == 0
    end

    test "concurrent holders are all counted" do
      parent = self()

      pids =
        for _ <- 1..5 do
          spawn(fn ->
            AshCell.with_tenant("acme", fn ->
              send(parent, :bound)
              receive do: (:release -> :ok)
            end)
          end)
        end

      for _ <- 1..5, do: assert_receive(:bound, 2_000)
      assert AshCell.Registry.active_binds("acme") == 5

      for pid <- pids, do: send(pid, :release)
      wait_until(fn -> AshCell.Registry.active_binds("acme") == 0 end)
    end

    test "nesting decrements the inner tenant, not the outer" do
      AshCell.with_tenant("outer", fn ->
        AshCell.with_tenant("inner", fn -> :ok end)

        # A naive restore would decrement whatever was being restored *to*,
        # leaving "inner" looking permanently busy and stalling every drain.
        assert AshCell.Registry.active_binds("inner") == 0
        assert AshCell.Registry.active_binds("outer") == 1
      end)
    end

    test "a stray unbind cannot drive the count negative" do
      # A negative count reads as quiescent, which would let a drain proceed
      # straight over live work.
      AshCell.Registry.unbound("phantom")
      AshCell.Registry.unbound("phantom")

      assert AshCell.Registry.active_binds("phantom") == 0
    end
  end

  describe "quiescence" do
    test "returns true once nothing is bound" do
      assert AshCell.Drain.await_quiescence("acme", 1_000)
    end

    test "waits for a bound process to finish" do
      parent = self()

      spawn(fn ->
        AshCell.with_tenant("acme", fn ->
          send(parent, :bound)
          Process.sleep(150)
        end)
      end)

      assert_receive :bound, 2_000
      assert AshCell.Drain.await_quiescence("acme", 3_000)
    end

    test "gives up at the deadline rather than hanging the deploy" do
      parent = self()

      holder =
        spawn(fn ->
          AshCell.with_tenant("acme", fn ->
            send(parent, :bound)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :bound, 2_000

      # A drain that waits forever is a deploy that hangs until the platform
      # sends SIGKILL, which loses the snapshot too.
      refute AshCell.Drain.await_quiescence("acme", 150)

      send(holder, :release)
    end
  end

  describe "draining the fleet" do
    test "closes every resident cell and reports them" do
      for tenant <- ~w(a b c), do: write(tenant, "Row")
      assert length(AshCell.resident_tenants()) == 3

      assert {:ok, report} = AshCell.drain(grace_ms: 500)

      assert Enum.sort(report.drained) == ~w(a b c)
      assert report.failed == %{}
      assert AshCell.resident_tenants() == []
    end

    test "data survives the drain and is readable after reactivation" do
      write("acme", "Survives Deploy")
      AshCell.drain(grace_ms: 500)

      # Simulates the next node picking the tenant up.
      AshCell.Manager.unseal()
      assert ["Survives Deploy"] = read("acme")
    end

    test "checkpoints the WAL so the file on disk is the whole database" do
      write("acme", "Checkpointed")
      path = AshCell.path_for("acme")

      AshCell.drain(grace_ms: 500)

      # Read the drained file directly, with no WAL sidecar in play.
      {:ok, repo_pid} = AshCell.TestRepo.start_link(name: nil, database: path, pool_size: 1)

      assert %{rows: [["Checkpointed"]]} =
               Ecto.Adapters.SQL.query!(repo_pid, "SELECT name FROM tenant_patients", [])
    end

    test "seals first, so a request cannot reactivate a tenant mid-drain" do
      write("acme", "Row")
      assert {:ok, _} = AshCell.drain(grace_ms: 500)

      assert AshCell.Manager.sealed?()
      assert {:error, :draining} = AshCell.Manager.ensure_started("acme")
    end

    test "draining an empty node is a no-op, not an error" do
      assert {:ok, %{drained: [], failed: %{}}} = AshCell.drain(grace_ms: 100)
    end

    test "reports how long it took" do
      for tenant <- ~w(a b), do: write(tenant, "Row")
      assert {:ok, report} = AshCell.drain(grace_ms: 500)
      assert is_integer(report.duration_ms)
    end
  end

  describe "draining one tenant" do
    test "leaves the rest of the fleet alone" do
      write("stays", "Row")
      write("goes", "Row")

      assert {:ok, _} = AshCell.Drain.drain_tenant("goes", nil, 500)

      assert "stays" in AshCell.resident_tenants()
      refute "goes" in AshCell.resident_tenants()
    end

    test "reports whether the cell went quiet before it was taken" do
      write("acme", "Row")
      assert {:ok, %{quiesced?: true}} = AshCell.Drain.drain_tenant("acme", nil, 500)
    end
  end

  defp write(tenant, name) do
    AshCell.with_tenant(tenant, fn -> TenantPatient.create!(name, tenant: tenant) end)
  end

  defp read(tenant) do
    AshCell.with_tenant(tenant, fn ->
      TenantPatient
      |> Ash.Query.set_tenant(tenant)
      |> Ash.read!()
      |> Enum.map(& &1.name)
      |> Enum.sort()
    end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end
end
