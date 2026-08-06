defmodule AshCell.RegressionTest do
  @moduledoc """
  Failures found by driving the demo, rather than by writing tests.

  Each of these was invisible to the suite because the suite never raced a cell's
  lifecycle against a caller, and never opened a database it could not decrypt.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias AshCell.Test.TenantPatient

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_regr_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "binding races the cell's lifecycle" do
    test "closing waits for in-flight work rather than yanking the cell" do
      # Found by clicking "hibernate" in the demo while the page reloaded its
      # data: the close raced a bound reader, and the reader failed deep inside
      # Ecto's registry with an ETS error nowhere near the cause.
      write("acme", "Row")

      for _ <- 1..40 do
        task = Task.async(fn -> AshCell.with_tenant("acme", fn -> read_bound() end) end)
        AshCell.close("acme")
        assert is_list(Task.await(task, 5_000))
      end
    end

    test "a bound cell is never chosen for eviction" do
      # Least-recently-started is not the same as unused: a LiveView can hold a
      # cell for hours while barely touching it.
      parent = self()

      spawn(fn ->
        AshCell.bind_held("pinned")
        send(parent, :held)
        receive do: (:stop -> :ok)
      end)

      assert_receive :held, 2_000

      for i <- 1..12, do: AshCell.with_tenant("filler_#{i}", fn -> :ok end)

      assert "pinned" in AshCell.resident_tenants()
    end

    test "binding recovers when the cell dies mid-call" do
      write("acme", "Recovered")
      {:ok, pid} = AshCell.Manager.ensure_started("acme")

      Process.exit(pid, :kill)

      assert ["Recovered"] = AshCell.with_tenant("acme", fn -> read_bound() end)
    end

    test "concurrent binders all survive repeated eviction" do
      write("acme", "Row")

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            for _ <- 1..10 do
              AshCell.with_tenant("acme", fn -> read_bound() end)
            end

            :done
          end)
        end

      closer = Task.async(fn -> for _ <- 1..25, do: AshCell.close("acme") end)

      assert Enum.all?(Task.await_many(tasks, 20_000), &(&1 == :done))
      Task.await(closer, 20_000)
    end
  end

  describe "a cell that cannot be opened" do
    test "fails fast instead of retrying a non-transient error", %{dir: dir} do
      # A destroyed key is permanent, but DBConnection's default backoff retried
      # for four seconds before surfacing it, so the demo appeared to hang.
      File.write!(Path.join(dir, "corrupt.db"), :crypto.strong_rand_bytes(8192))

      {elapsed_us, result} =
        :timer.tc(fn -> AshCell.Manager.ensure_started("corrupt") end)

      assert {:error, _} = result
      assert div(elapsed_us, 1000) < 2_000
    end

    test "is quarantined and then refused without re-attempting", %{dir: dir} do
      File.write!(Path.join(dir, "corrupt.db"), :crypto.strong_rand_bytes(8192))

      assert {:error, _} = AshCell.Manager.ensure_started("corrupt")
      assert Map.has_key?(AshCell.Manager.quarantined(), "corrupt")

      # The second attempt must not pay the failure again, or every retry logs a
      # fresh crash and buries the original cause.
      {elapsed_us, result} = :timer.tc(fn -> AshCell.Manager.ensure_started("corrupt") end)

      assert {:error, {:quarantined, _}} = result
      assert div(elapsed_us, 1000) < 100
    end

    test "releasing quarantine allows a retry once the cause is fixed", %{dir: dir} do
      path = Path.join(dir, "fixable.db")
      File.write!(path, :crypto.strong_rand_bytes(8192))

      assert {:error, _} = AshCell.Manager.ensure_started("fixable")
      assert {:error, {:quarantined, _}} = AshCell.Manager.ensure_started("fixable")

      File.rm!(path)
      assert :ok = AshCell.Manager.release("fixable")
      assert {:ok, _pid} = AshCell.Manager.ensure_started("fixable")
    end
  end

  defp write(tenant, name) do
    AshCell.with_tenant(tenant, fn -> TenantPatient.create!(name, tenant: tenant) end)
  end

  defp read_bound do
    TenantPatient
    |> Ash.Query.set_tenant(AshCell.bound_tenant())
    |> Ash.read!()
    |> Enum.map(& &1.name)
  end
end

defmodule AshCell.KeyFailClosedTest do
  @moduledoc """
  A missing key must stop the cell, not quietly produce a plaintext database.

  Found in the demo: a clinic whose key had been destroyed came back as an
  unencrypted SQLite file, reported as "revoked" and "NOT encrypted" at the same
  time. SQLite creates a plaintext database perfectly happily when handed no key,
  so the degradation is silent and the result is unprotected data under a name
  that claims protection.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    dir = Path.join(System.tmp_dir!(), "ash_cell_key_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "a tenant with no key refuses to start", %{dir: dir} do
    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrator: AshCell.TestMigrations,
       key_for: fn
         "revoked" -> nil
         tenant -> AshCell.Test.Keys.for_tenant(tenant)
       end}
    )

    assert {:error, _} = AshCell.Manager.ensure_started("revoked")
    refute File.exists?(Path.join(dir, "revoked.db"))
  end

  test "other tenants are unaffected by one missing key", %{dir: dir} do
    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrator: AshCell.TestMigrations,
       key_for: fn
         "revoked" -> nil
         tenant -> AshCell.Test.Keys.for_tenant(tenant)
       end}
    )

    assert {:error, _} = AshCell.Manager.ensure_started("revoked")
    assert {:ok, _pid} = AshCell.Manager.ensure_started("healthy")
  end

  test "a fleet with no key function still runs unencrypted, deliberately", %{dir: dir} do
    # Encryption is opt-in. Only a fleet that asked for keys is failed closed when
    # one is missing; otherwise plaintext is the configured intent, not a fallback.
    start_supervised!(
      {AshCell, repo: AshCell.TestRepo, dir: dir, migrator: AshCell.TestMigrations}
    )

    assert {:ok, _pid} = AshCell.Manager.ensure_started("plaintext")
  end
end
