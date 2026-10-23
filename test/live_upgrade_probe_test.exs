defmodule AshCell.LiveUpgradeProbeTest do
  @moduledoc """
  A probe of what happens when new code and a new migration reach a running node
  whose cells are resident, first by hand and then through `AshCell.upgrade/1`.
  See [DD-15](../docs/design/DD-15-live-schema-upgrade.md).

  Each test drives load from one writer and one reader per cell against a resource
  compiled at runtime, then hot-loads a second version of that same module. The
  numbers it prints are the point; the assertions pin the behaviour it observed, so
  that a library change which moves it shows up here first.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  @resource AshCell.Test.UpgradeWidget
  @domain AshCell.Test.UpgradeDomain
  @cell_count 8

  setup ctx do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "ash_cell_lu_#{n}")
    mig_dir = Path.join(System.tmp_dir!(), "ash_cell_lu_mig_#{n}")
    File.mkdir_p!(mig_dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    on_exit(fn -> File.rm_rf!(mig_dir) end)

    write_migration(
      mig_dir,
      n,
      1,
      "CREATE TABLE upgrade_widgets (id TEXT PRIMARY KEY, name TEXT NOT NULL)"
    )

    load_code(ctx.binaries, :v1)

    {:ok, n: n, dir: dir, mig_dir: mig_dir}
  end

  defp start_fleet(dir, mig_dir) do
    start_supervised!({AshCell, repo: AshCell.TestRepo, dir: dir, migrations_path: mig_dir})
  end

  defp cell_keys(n), do: for(i <- 1..@cell_count, do: "lu-#{n}-#{i}")

  defp write_migration(mig_dir, n, version, sql, before \\ "") do
    module = "AshCell.Test.LiveUpgradeMigration#{n}V#{version}"

    File.write!(Path.join(mig_dir, "#{version}_m#{n}_v#{version}.exs"), """
    defmodule #{module} do
      use Ecto.Migration

      def up do
        #{before}
        execute #{inspect(sql)}
      end

      def down, do: :ok
    end
    """)
  end

  defp migrations(mig_dir), do: AshCell.Migrations.compile(mig_dir)

  setup_all do
    Code.put_compiler_option(:ignore_module_conflict, true)

    binaries =
      try do
        binaries = Map.new([:v1, :expand, :breaking], &{&1, compile_version(&1)})
        load_code(binaries, :v1)

        unless function_exported?(@domain, :spark_is, 0) do
          Code.compile_string("""
          defmodule #{inspect(@domain)} do
            use Ash.Domain, validate_config_inclusion?: false

            resources do
              resource #{inspect(@resource)}
            end
          end
          """)
        end

        binaries
      after
        Code.put_compiler_option(:ignore_module_conflict, false)
      end

    {:ok, binaries: binaries}
  end

  # Each version is compiled with no earlier version loaded. Recompiling over a loaded
  # Ash resource builds its Ecto schema from the old module: Spark's DSL lookup calls
  # the loaded module's `entities/1` before the attributes being compiled, so
  # `Ash.Resource.Info` reports v2 while `__schema__(:fields)` is still v1's.
  defp compile_version(version) do
    :code.purge(@resource)
    :code.delete(@resource)
    :code.purge(@resource)

    attributes =
      case version do
        :v1 ->
          "attribute :name, :string, allow_nil?: false, public?: true"

        :expand ->
          "attribute :name, :string, allow_nil?: false, public?: true\n    attribute :sku, :string, public?: true"

        :breaking ->
          "attribute :title, :string, allow_nil?: false, public?: true"
      end

    accepts =
      case version do
        :v1 -> "[:name]"
        :expand -> "[:name, :sku]"
        :breaking -> "[:title]"
      end

    {@resource, binary} =
      Code.compile_string("""
      defmodule #{inspect(@resource)} do
        use Ash.Resource, domain: #{inspect(@domain)}, data_layer: AshSqlite.DataLayer, validate_domain_inclusion?: false

        sqlite do
          table "upgrade_widgets"
          repo AshCell.TestRepo
        end

        multitenancy do
          strategy :context
        end

        attributes do
          uuid_primary_key :id
          #{attributes}
        end

        actions do
          defaults [:read, create: #{accepts}]
        end
      end
      """)
      |> List.keyfind(@resource, 0)

    binary
  end

  # Loading a prebuilt binary is the whole of what a hot upgrade does to a module.
  defp load_code(binaries, version) do
    soft_purge()
    {:module, @resource} = :code.load_binary(@resource, ~c"nofile", Map.fetch!(binaries, version))
    :ok
  end

  defp soft_purge do
    unless :code.soft_purge(@resource) do
      Process.sleep(1)
      soft_purge()
    end
  end

  defp create_args do
    has? = &(Ash.Resource.Info.attribute(@resource, &1) != nil)
    label = "w#{System.unique_integer([:positive])}"

    %{}
    |> then(&if(has?.(:name), do: Map.put(&1, :name, label), else: &1))
    |> then(&if(has?.(:title), do: Map.put(&1, :title, label), else: &1))
    |> then(&if(has?.(:sku), do: Map.put(&1, :sku, "sku-" <> label), else: &1))
  end

  defp attempt(:write, cell) do
    @resource
    |> Ash.Changeset.for_create(:create, create_args(), tenant: cell)
    |> Ash.create()
  end

  defp attempt(:read, cell), do: Ash.read(@resource, tenant: cell)

  defp short(%{__exception__: true} = e), do: e |> Exception.message() |> String.slice(0, 160)
  defp short(other), do: other |> inspect() |> String.slice(0, 160)

  defp start_load(cells) do
    table = :ets.new(:lu_outcomes, [:public, :duplicate_bag, write_concurrency: true])
    stop = :atomics.new(1, [])

    pids =
      for cell <- cells, kind <- [:write, :read] do
        spawn_link(fn -> loop(table, stop, cell, kind) end)
      end

    {table, stop, pids}
  end

  defp loop(table, stop, cell, kind) do
    if :atomics.get(stop, 1) == 0 do
      outcome =
        try do
          case attempt(kind, cell) do
            {:ok, _} -> :ok
            {:error, e} -> {:error, short(e)}
          end
        rescue
          e -> {:error, short(e)}
        catch
          k, v -> {:error, short({k, v})}
        end

      :ets.insert(table, {cell, kind, System.monotonic_time(:microsecond), outcome})
      loop(table, stop, cell, kind)
    end
  end

  defp stop_load({table, stop, pids}) do
    :atomics.put(stop, 1, 1)

    for pid <- pids do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}, 5_000
    end

    summarise(table, Enum.uniq(for {c, _, _, _} <- :ets.tab2list(table), do: c))
  end

  defp summarise(table, cells) do
    rows = :ets.tab2list(table)

    per_cell =
      Map.new(cells, fn cell ->
        mine = for {^cell, _, t, o} <- rows, do: {t, o}
        failures = Enum.count(mine, fn {_, o} -> o != :ok end)

        pause_ms =
          mine
          |> Enum.filter(fn {_, o} -> o == :ok end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [a, b] -> b - a end)
          |> Enum.max(fn -> 0 end)
          |> div(1000)

        {cell, %{failures: failures, requests: length(mine), pause_ms: pause_ms}}
      end)

    sample = Enum.find_value(rows, fn {_, _, _, o} -> match?({:error, _}, o) && elem(o, 1) end)
    total = per_cell |> Map.values() |> Enum.map(& &1.failures) |> Enum.sum()
    requests = per_cell |> Map.values() |> Enum.map(& &1.requests) |> Enum.sum()

    %{per_cell: per_cell, total: total, requests: requests, sample: sample}
  end

  defp report(label, summary) do
    cells = Enum.sort(summary.per_cell)
    IO.puts("[probe] #{label}: failures=#{summary.total}/#{summary.requests}")

    IO.puts(
      "[probe] #{label}: failures per cell #{inspect(Enum.map(cells, fn {_, s} -> s.failures end), charlists: :as_lists)}"
    )

    IO.puts(
      "[probe] #{label}: pause_ms per cell #{inspect(Enum.map(cells, fn {_, s} -> s.pause_ms end), charlists: :as_lists)}"
    )

    if summary.sample, do: IO.puts("[probe] #{label}: sample error #{summary.sample}")
  end

  defp open_all(cells) do
    Map.new(cells, fn cell ->
      {:ok, pid} = AshCell.Manager.ensure_started(cell)
      {cell, pid}
    end)
  end

  defp migrate_in_place(pids, mig_dir) do
    compiled = migrations(mig_dir)

    for {cell, pid} <- Enum.sort(pids) do
      repo_pid = AshCell.Cell.repo_pid(pid)

      {us, result} =
        :timer.tc(fn -> AshCell.Migrations.run(AshCell.TestRepo, repo_pid, compiled) end)

      {cell, result, div(us, 1000)}
    end
  end

  test "a resident cell does not move version when a migration file arrives", ctx do
    start_fleet(ctx.dir, ctx.mig_dir)
    [cell | _] = cells = cell_keys(ctx.n)
    open_all(cells)

    write_migration(ctx.mig_dir, ctx.n, 2, "ALTER TABLE upgrade_widgets ADD COLUMN sku TEXT")

    :ok = AshCell.Manager.close(cell)
    {:ok, pid} = AshCell.Manager.ensure_started(cell)
    reopened = AshCell.Cell.info(pid).schema_version

    {:ok, fresh_pid} = AshCell.Manager.ensure_started("lu-#{ctx.n}-never-opened")
    fresh = AshCell.Cell.info(fresh_pid).schema_version

    IO.puts(
      "[probe] reopened resident cell version=#{reopened}, never-opened cell version=#{fresh}"
    )

    assert reopened == 1
    assert fresh == 1
  end

  test "after reload_migrations, a fresh cell and a reopened cell open at the new version",
       ctx do
    start_fleet(ctx.dir, ctx.mig_dir)
    [cell | _] = cell_keys(ctx.n)
    {:ok, _} = AshCell.Manager.ensure_started(cell)

    write_migration(ctx.mig_dir, ctx.n, 2, "ALTER TABLE upgrade_widgets ADD COLUMN sku TEXT")
    assert {:ok, 2} = AshCell.reload_migrations()

    {:ok, fresh_pid} = AshCell.Manager.ensure_started("lu-#{ctx.n}-never-opened")
    :ok = AshCell.Manager.close(cell)
    {:ok, pid} = AshCell.Manager.ensure_started(cell)

    assert AshCell.Cell.info(fresh_pid).schema_version == 2
    assert AshCell.Cell.info(pid).schema_version == 2
  end

  test "migrate_all migrates a resident cell in place and leaves it resident", ctx do
    start_fleet(ctx.dir, ctx.mig_dir)
    [cell | _] = cell_keys(ctx.n)
    {:ok, pid} = AshCell.Manager.ensure_started(cell)

    write_migration(ctx.mig_dir, ctx.n, 2, "ALTER TABLE upgrade_widgets ADD COLUMN sku TEXT")
    {:ok, 2} = AshCell.reload_migrations()

    assert AshCell.Manager.migrate_all([cell]) == [{cell, {:ok, 2}}]
    assert AshCell.Registry.lookup(cell) == {:ok, pid}
    assert AshCell.Cell.info(pid).schema_version == 2
  end

  test "loading expand code before migrating fails requests on unmigrated cells", ctx do
    start_fleet(ctx.dir, ctx.mig_dir)
    cells = cell_keys(ctx.n)
    open_all(cells)
    write_migration(ctx.mig_dir, ctx.n, 2, "ALTER TABLE upgrade_widgets ADD COLUMN sku TEXT")

    load = start_load(cells)
    Process.sleep(300)
    load_code(ctx.binaries, :expand)
    Process.sleep(500)
    summary = stop_load(load)

    report("expand code first", summary)
    assert summary.total > 0
  end

  test "a breaking migration fails in both orders", ctx do
    start_fleet(ctx.dir, ctx.mig_dir)
    cells = cell_keys(ctx.n)
    pids = open_all(cells)

    write_migration(
      ctx.mig_dir,
      ctx.n,
      2,
      "ALTER TABLE upgrade_widgets RENAME COLUMN name TO title"
    )

    load = start_load(cells)
    Process.sleep(300)
    timings = migrate_in_place(pids, ctx.mig_dir)
    Process.sleep(200)
    load_code(ctx.binaries, :breaking)
    Process.sleep(300)
    migrate_first = stop_load(load)

    report("breaking, migrate first", migrate_first)
    IO.puts("[probe] breaking migrate ms per cell #{inspect(Enum.map(timings, &elem(&1, 2)))}")
    assert Enum.all?(timings, &match?({_, {:ok, 2}, _}, &1))
    assert migrate_first.total > 0

    n2 = System.unique_integer([:positive])
    load_code(ctx.binaries, :v1)
    cells2 = for i <- 1..@cell_count, do: "lu-#{n2}-#{i}"
    mig_dir2 = Path.join(System.tmp_dir!(), "ash_cell_lu_mig_#{n2}")
    File.mkdir_p!(mig_dir2)
    on_exit(fn -> File.rm_rf!(mig_dir2) end)

    # The fleet's migration list is fixed at init, so the second order's cells open at
    # v1 from the first set and are migrated by hand from a second set.
    pids2 = open_all(cells2)

    write_migration(
      mig_dir2,
      n2,
      1,
      "CREATE TABLE upgrade_widgets (id TEXT PRIMARY KEY, name TEXT NOT NULL)"
    )

    write_migration(mig_dir2, n2, 2, "ALTER TABLE upgrade_widgets RENAME COLUMN name TO title")

    load2 = start_load(cells2)
    Process.sleep(300)
    load_code(ctx.binaries, :breaking)
    Process.sleep(200)
    migrate_in_place(pids2, mig_dir2)
    Process.sleep(300)
    code_first = stop_load(load2)

    report("breaking, code first", code_first)
    assert code_first.total > 0
  end

  defp report_upgrade(label, report) do
    migrated = Enum.sort(report.migrated)

    IO.puts(
      "[probe] #{label}: upgrade #{report.duration_ms}ms, migrate ms per cell " <>
        inspect(Enum.map(migrated, fn {_, m} -> m.duration_ms end), charlists: :as_lists)
    )
  end

  defp sample_errors(table, limit) do
    table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {_, _, _, {:error, e}} -> [e]
      _ -> []
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(limit)
  end

  test "expand migration under v1 load, via AshCell.upgrade/1, costs no failures", ctx do
    start_fleet(ctx.dir, ctx.mig_dir)
    cells = cell_keys(ctx.n)
    pids = open_all(cells)
    write_migration(ctx.mig_dir, ctx.n, 2, "ALTER TABLE upgrade_widgets ADD COLUMN sku TEXT")

    load = start_load(cells)
    Process.sleep(300)
    {:ok, upgrade} = AshCell.upgrade()
    load_code(ctx.binaries, :expand)
    Process.sleep(500)
    summary = stop_load(load)

    info_versions =
      Enum.map(Enum.sort(pids), fn {_, pid} -> AshCell.Cell.info(pid).schema_version end)

    report("expand-upgrade-load", summary)
    report_upgrade("expand", upgrade)

    assert upgrade.target == 2
    assert upgrade.failed == %{}
    assert Map.keys(upgrade.migrated) |> Enum.sort() == Enum.sort(cells)
    assert Enum.all?(Map.values(upgrade.migrated), &match?(%{from: 1, to: 2}, &1))
    assert Enum.all?(info_versions, &(&1 == 2))
    assert summary.total == 0
  end

  # The cliff DD-15 owes: the parameter is the migration's duration. The sleep holds
  # the connection inside the migration's transaction, so the pool of one queues
  # every request for that cell behind it.
  defp slow_ms, do: "LU_SLOW_MS" |> System.get_env("1500") |> String.to_integer()

  test "a slow in-place migration under load", ctx do
    start_fleet(ctx.dir, ctx.mig_dir)
    cells = cell_keys(ctx.n)
    open_all(cells)

    write_migration(
      ctx.mig_dir,
      ctx.n,
      2,
      "ALTER TABLE upgrade_widgets ADD COLUMN sku TEXT",
      "Process.sleep(#{slow_ms()})"
    )

    load = start_load(cells)
    Process.sleep(300)
    {:ok, upgrade} = AshCell.upgrade()
    Process.sleep(300)
    {table, _, _} = load
    summary = stop_load(load)

    report("slow-upgrade-load", summary)
    report_upgrade("slow", upgrade)
    IO.puts("[probe] slow: error reasons #{inspect(sample_errors(table, 3))}")

    # 1.5s and 3s are a pause, not errors. At 6s DBConnection's default queue
    # settings drop requests that waited 1.6-5.1s; run with LU_SLOW_MS=6000 to see it.
    assert upgrade.failed == %{}
    assert map_size(upgrade.migrated) == @cell_count
    assert summary.total == 0
  end

  test "a migration that fails in one cell quarantines that cell and migrates the rest",
       ctx do
    gate = {__MODULE__, :fail, ctx.n}
    start_fleet(ctx.dir, ctx.mig_dir)
    [doomed | rest] = cells = cell_keys(ctx.n)
    pids = open_all(cells)
    :persistent_term.put(gate, AshCell.Cell.repo_pid(pids[doomed]))
    on_exit(fn -> :persistent_term.erase(gate) end)

    write_migration(
      ctx.mig_dir,
      ctx.n,
      2,
      "ALTER TABLE upgrade_widgets ADD COLUMN sku TEXT",
      "if repo().get_dynamic_repo() == :persistent_term.get(#{inspect(gate)}, nil), do: raise(\"boom\")"
    )

    {:ok, upgrade} = AshCell.upgrade()
    IO.puts("[probe] failing cell: failed=#{inspect(upgrade.failed)}")

    assert Map.keys(upgrade.failed) == [doomed]
    assert Map.has_key?(AshCell.Manager.quarantined(), doomed)
    assert AshCell.Registry.lookup(doomed) == :error
    assert Enum.sort(Map.keys(upgrade.migrated)) == Enum.sort(rest)
  end

  test "a slow migration in one cell delays activation of every other cell", ctx do
    gate = {__MODULE__, :slow, ctx.n}

    # The sleep is gated so only the cell opened while the gate is set is slow; every
    # cell runs the same migration list.
    write_migration(
      ctx.mig_dir,
      ctx.n,
      2,
      "CREATE TABLE slow_marker (id INTEGER)",
      "if :persistent_term.get(#{inspect(gate)}, false), do: Process.sleep(1500)"
    )

    start_fleet(ctx.dir, ctx.mig_dir)

    {control_us, {:ok, _}} =
      :timer.tc(fn -> AshCell.Manager.ensure_started("lu-#{ctx.n}-control") end)

    :persistent_term.put(gate, true)
    slow = Task.async(fn -> AshCell.Manager.ensure_started("lu-#{ctx.n}-slow") end)
    Process.sleep(50)
    :persistent_term.erase(gate)

    {blocked_us, {:ok, _}} =
      :timer.tc(fn -> AshCell.Manager.ensure_started("lu-#{ctx.n}-other") end)

    {:ok, _} = Task.await(slow, 5_000)

    IO.puts(
      "[probe] activation of an unrelated cell: #{div(blocked_us, 1000)}ms during a 1500ms migration, control #{div(control_us, 1000)}ms"
    )

    assert blocked_us > 1_000_000
    assert control_us < 1_000_000
  end
end
