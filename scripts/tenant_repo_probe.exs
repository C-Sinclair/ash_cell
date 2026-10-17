# Probe: with upstream's `c:AshSqlite.Repo.tenant_repo/2`, what can replace the three
# things `AshCell.Binder.bind/3` used to do after each statement?
#
# The fork's `tenant_binder` wrapped the statement, so AshCell ran code on both sides
# of it. Upstream asks `tenant_repo/2` for an instance, binds it, runs the statement,
# and restores the previous binding itself. Nothing of AshCell's runs afterwards. The
# old binder used the "after" for three duties, and this measures a candidate for each:
#
#   A. the in-flight count a drain waits on: is the connection pool's own
#      checkout state (`DBConnection.get_connection_metrics/1`) a usable count?
#   B. the read cache's post-commit invalidation: does the repo's telemetry
#      `[..., :query]` event fire for every write and for `commit`, in the writer
#      process, after the commit is durable, with the instance still bound?
#   C. the bound cell key: is the process's dynamic repo a faithful record of which
#      instance a statement is running on, during and after it?
#
#     mix run scripts/tenant_repo_probe.exs

defmodule TenantRepoProbe.Instances do
  @moduledoc false
  def put(tenant, pid), do: :persistent_term.put({__MODULE__, tenant}, pid)
  def get(tenant), do: :persistent_term.get({__MODULE__, tenant})

  def record(entry) do
    Agent.update(__MODULE__, &[entry | &1])
  end

  def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
  def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
end

defmodule TenantRepoProbe.Repo do
  use AshSqlite.Repo, otp_app: :ash_cell

  def installed_extensions, do: []
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
  def write_transactions?, do: true

  def tenant_repo(tenant, context) do
    if Process.get(:probe_record?, true) do
      TenantRepoProbe.Instances.record({:tenant_repo, tenant, context.type})
    end

    Process.put(:probe_returned_at, System.monotonic_time())
    TenantRepoProbe.Instances.get(tenant)
  end
end

defmodule TenantRepoProbe.Row do
  use Ash.Resource,
    domain: TenantRepoProbe.Domain,
    data_layer: AshSqlite.DataLayer,
    validate_domain_inclusion?: false

  sqlite do
    table "rows"
    repo TenantRepoProbe.Repo
  end

  multitenancy do
    strategy :context
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:name]]

    update :rename do
      require_atomic? true
      accept [:name]
    end

    create :create_twice do
      accept [:name]

      change after_action(fn changeset, record, _context ->
               Ash.create!(TenantRepoProbe.Row, %{name: record.name <> "-again"},
                 tenant: changeset.tenant
               )

               {:ok, record}
             end)
    end
  end
end

defmodule TenantRepoProbe.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource TenantRepoProbe.Row
  end
end

defmodule TenantRepoProbe do
  alias TenantRepoProbe.{Instances, Repo, Row}

  @event [:tenant_repo_probe, :repo, :query]

  def run do
    Logger.configure(level: :info)
    {:ok, _} = Agent.start_link(fn -> [] end, name: Instances)

    dir = Path.join(System.tmp_dir!(), "ash_cell_tenant_repo_probe")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    paths =
      for tenant <- ["acme", "globex"], into: %{} do
        path = Path.join(dir, "#{tenant}.db")
        {:ok, pid} = Repo.start_link(name: nil, database: path, pool_size: 1)

        Ecto.Adapters.SQL.query!(
          pid,
          "CREATE TABLE rows (id TEXT PRIMARY KEY, name TEXT NOT NULL)",
          []
        )

        Instances.put(tenant, pid)
        {tenant, path}
      end

    section_c_binding()
    section_b_telemetry(paths)
    section_a_in_flight()
    section_d_window()
    section_e_handler_cost()
  end

  # --- E ----------------------------------------------------------------------

  # Every statement on the repo fires the event, reads included, so a handler
  # attached for writes is paid by every read. This is the shape of its early exit:
  # one process-dictionary read and one binary prefix match.
  def early_exit(_event, _measurements, %{query: "SELECT" <> _}, _config) do
    Process.get(:probe_open_write)
  end

  def early_exit(_event, _measurements, _metadata, _config), do: :ok

  defp section_e_handler_cost do
    IO.puts("\nE. what a handler that returns early for reads costs a read\n")

    measure = fn ->
      for _ <- 1..5 do
        {us, _} = :timer.tc(fn -> for _ <- 1..2_000, do: Ash.read!(Row, tenant: "acme") end)
        us / 2_000
      end
      |> median()
    end

    without = measure.()
    :telemetry.attach("early_exit", @event, &__MODULE__.early_exit/4, nil)
    with_handler = measure.()
    :telemetry.detach("early_exit")
    again = measure.()

    IO.puts("  Ash.read!/2, no handler:    #{without} µs")
    IO.puts("  Ash.read!/2, with handler:  #{with_handler} µs")
    IO.puts("  Ash.read!/2, no handler:    #{again} µs  (run-to-run spread)")
    IO.puts("  median of 5 x 2,000 each")
  end

  # --- D ----------------------------------------------------------------------

  # The time between `tenant_repo/2` returning and the statement asking the pool
  # for the connection. Nothing counts the statement in that window: it is not yet
  # queued, so the pool's metrics cannot see it. Measured as the time from the
  # return to the query event, less what the event itself reports for queueing,
  # running, and decoding.
  defp section_d_window do
    IO.puts("\nD. the uncounted window, tenant_repo/2 return to pool checkout\n")
    Process.put(:probe_record?, false)
    parent = self()

    :telemetry.attach(
      "window",
      @event,
      fn _event, m, _metadata, _ ->
        case Process.delete(:probe_returned_at) do
          nil ->
            :ok

          t0 ->
            spent =
              Map.get(m, :queue_time, 0) + Map.get(m, :query_time, 0) +
                Map.get(m, :decode_time, 0)

            send(parent, {:window, System.monotonic_time() - t0 - spent})
        end
      end,
      nil
    )

    for {label, fun} <- [
          {"Ash.read!/2", fn -> Ash.read!(Row, tenant: "acme") end},
          {"Ash.count!/2", fn -> Ash.count!(Row, tenant: "acme") end}
        ] do
      for _ <- 1..1_000, do: fun.()

      windows =
        for _ <- 1..1_000 do
          receive do: ({:window, native} ->
                         System.convert_time_unit(native, :native, :nanosecond) / 1_000)
        end
        |> Enum.sort()

      IO.puts(
        "  #{String.pad_trailing(label, 14)} median #{Float.round(Enum.at(windows, 500), 1)} µs, " <>
          "p99 #{Float.round(Enum.at(windows, 989), 1)} µs, max #{Float.round(List.last(windows), 1)} µs (1,000 calls)"
      )
    end

    :telemetry.detach("window")
  end

  # --- C ----------------------------------------------------------------------

  defp section_c_binding do
    IO.puts("\nC. the bound instance, during and after a statement\n")
    acme = Instances.get("acme")

    before = Repo.get_dynamic_repo()
    Ash.create!(Row, %{name: "c"}, tenant: "acme")
    after_create = Repo.get_dynamic_repo()

    IO.puts("  before a statement: #{inspect(before)}")
    IO.puts("  after a statement:  #{inspect(after_create)}  (restored by the data layer)")

    inside =
      Ash.transaction(Row, fn -> Repo.get_dynamic_repo() end, tenant: "acme")

    IO.puts("  inside an Ash.transaction/3: #{inspect(inside)}, acme is #{inspect(acme)}")

    Instances.reset()
    Ash.create!(Row, %{name: "twice"}, action: :create_twice, tenant: "acme")
    IO.puts("  tenant_repo/2 calls for a two-insert action: #{inspect(Instances.calls())}")
  end

  # --- B ----------------------------------------------------------------------

  defp section_b_telemetry(paths) do
    IO.puts("\nB. what the repo's query event reports, per Ash call\n")

    parent = self()

    :telemetry.attach(
      "probe",
      @event,
      fn _event, _measurements, metadata, _ ->
        bound = Repo.get_dynamic_repo()

        in_txn =
          if is_pid(bound),
            do: Repo.in_transaction?(),
            else: :unbound

        # Read the file through a separate connection: a committed row is visible
        # to it, an uncommitted one is not. This is what "after the commit" means.
        visible =
          try do
            rows_on_disk(paths["acme"])
          rescue
            e -> {:error, Exception.message(e)}
          end

        send(
          parent,
          {:event, self(), String.slice(metadata.query, 0, 40), bound, in_txn, visible}
        )
      end,
      nil
    )

    row = Ash.create!(Row, %{name: "ada"}, tenant: "acme")
    report("Ash.create!/3 (an action Ash wraps in a transaction)")

    row |> Ash.Changeset.for_update(:rename, %{name: "ada l"}, tenant: "acme") |> Ash.update!()
    report("atomic update (require_atomic? true)")

    Ash.bulk_create!([%{name: "x"}, %{name: "y"}], Row, :create, tenant: "acme")
    report("Ash.bulk_create!/4")

    Ash.read!(Row, tenant: "acme")
    report("Ash.read!/2")

    Ash.count!(Row, tenant: "acme")
    report("Ash.count!/2")

    Ash.transaction(
      Row,
      fn ->
        Ash.create!(Row, %{name: "doomed"}, tenant: "acme")
        Repo.rollback(:no)
      end,
      tenant: "acme"
    )

    report("Ash.transaction/3 that rolls back")

    Task.async(fn -> Ash.create!(Row, %{name: "from a task"}, tenant: "acme") end)
    |> Task.await()

    report("a create from another process (events arrive from that pid)")

    :telemetry.detach("probe")
  end

  defp report(label) do
    IO.puts("  #{label}")
    me = self()

    for {:event, pid, sql, bound, in_txn, visible} <- drain() do
      who = if pid == me, do: "caller", else: inspect(pid)

      IO.puts(
        "    #{String.pad_trailing(inspect(sql), 44)} from #{who}, bound #{inspect(bound)}, " <>
          "in_transaction? #{inspect(in_txn)}, rows another connection sees: #{visible}"
      )
    end
  end

  defp drain(acc \\ []) do
    receive do
      {:event, _, _, _, _, _} = event -> drain([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp rows_on_disk(path) do
    {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT count(*) FROM rows")
    {:ok, [[n]]} = Exqlite.Sqlite3.fetch_all(db, stmt)
    Exqlite.Sqlite3.close(db)
    n
  end

  # --- A ----------------------------------------------------------------------

  defp section_a_in_flight do
    IO.puts("\nA. the pool's checkout state as an in-flight count\n")

    acme = Instances.get("acme")
    %{pid: pool} = Ecto.Adapter.lookup_meta(acme)

    IO.puts("  idle:                                      #{in_flight(pool)}")

    parent = self()

    holder =
      spawn(fn ->
        Ash.transaction(
          Row,
          fn ->
            send(parent, :holding)
            receive do: (:release -> :ok)
          end,
          tenant: "acme"
        )

        send(parent, :released)
      end)

    receive do: (:holding -> :ok)
    IO.puts("  an Ash transaction open, nothing else:     #{in_flight(pool)}")

    waiters =
      for _ <- 1..3 do
        spawn(fn -> Ash.read!(Row, tenant: "acme") end)
      end

    Process.sleep(50)
    IO.puts("  ... and three reads queued behind it:      #{in_flight(pool)}")

    send(holder, :release)
    receive do: (:released -> :ok)
    wait_until(fn -> Enum.all?(waiters, &(not Process.alive?(&1))) end)
    IO.puts("  everything finished:                       #{in_flight(pool)}")

    slow =
      spawn(fn ->
        Ecto.Adapters.SQL.query!(
          acme,
          "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 3000000) SELECT count(*) FROM n",
          []
        )
      end)

    Process.sleep(20)
    IO.puts("  one slow statement running, no transaction: #{in_flight(pool)}")
    wait_until(fn -> not Process.alive?(slow) end)

    samples =
      for _ <- 1..5 do
        {us, _} = :timer.tc(fn -> for _ <- 1..1_000, do: in_flight(pool) end)
        us / 1_000
      end

    IO.puts("\n  cost of asking, idle pool, median of 5 x 1,000: #{median(samples)} µs")

    samples =
      for _ <- 1..5 do
        {us, _} = :timer.tc(fn -> for _ <- 1..1_000, do: Ash.read!(Row, tenant: "acme") end)
        us / 1_000
      end

    IO.puts("  one Ash.read!/2 end to end, median of 5 x 1,000: #{median(samples)} µs")
  end

  defp in_flight(pool) do
    [%{ready_conn_count: ready, checkout_queue_length: queued}] =
      DBConnection.get_connection_metrics(pool)

    1 - ready + queued
  end

  defp wait_until(fun) do
    if fun.(), do: :ok, else: Process.sleep(5) && wait_until(fun)
  end

  defp median(samples),
    do: samples |> Enum.sort() |> Enum.at(div(length(samples), 2)) |> Float.round(2)
end

TenantRepoProbe.run()
