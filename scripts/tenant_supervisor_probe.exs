# Probe: what does ash_sqlite PR #246's `AshSqlite.MultiTenancy.tenant_repo/3` cost a
# statement on a tenant that is already open?
#
# The PR resolves a tenant by calling `DynamicSupervisor.start_child/2` every time,
# and treats `{:error, {:already_started, pid}}` as the warm case. That makes one
# DynamicSupervisor per repo a stop on every tenanted statement. This measures that,
# against three other ways to answer `tenant_repo/2` for the same files:
#
#   fixed         a pid from :persistent_term; the floor, nothing to resolve
#   lookup_first  the PR's own Registry and `Tenant.instance/2`, calling start_child
#                 only on a miss -- the PR before its review changed it
#   pr            `AshSqlite.MultiTenancy.tenant_repo/3` as the PR has it
#   ash_cell      `AshCell.Binder.tenant_repo/2` through `use AshCell.Repo`
#
# Standalone, because the PR is not in a release and AshCell's mix.lock pins
# upstream main. Run from the repository root:
#
#     elixir scripts/tenant_supervisor_probe.exs

pr_head = "82c20bb3301e9daedd4b6f588f3719394263eced"

Mix.install(
  [
    {:ash_sqlite, github: "C-Sinclair/ash_sqlite", ref: pr_head, override: true},
    {:ash_cell, path: Path.expand("..", __DIR__)}
  ],
  config: [
    ash: [
      default_string_length_count: :codepoints,
      validate_domain_resource_inclusion?: false,
      validate_domain_config_inclusion?: false
    ],
    logger: [level: :warning]
  ]
)

defmodule Probe.Fixed do
  @moduledoc false
  def put(tenant, pid), do: :persistent_term.put({__MODULE__, tenant}, pid)
  def get(tenant), do: :persistent_term.get({__MODULE__, tenant})
end

defmodule Probe.FixedRepo do
  use AshSqlite.Repo, otp_app: :probe
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
  def tenant_repo(tenant, _context), do: Probe.Fixed.get(tenant)
end

defmodule Probe.PrRepo do
  use AshSqlite.Repo, otp_app: :probe
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}

  def tenant_repo(tenant, context),
    do: AshSqlite.MultiTenancy.tenant_repo(__MODULE__, tenant, context)
end

defmodule Probe.LookupFirstRepo do
  use AshSqlite.Repo, otp_app: :probe
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}

  def tenant_repo(tenant, context) do
    with [{pid, _}] <- Registry.lookup(__MODULE__.TenantRegistry, tenant),
         {:ok, instance} <- AshSqlite.MultiTenancy.Tenant.instance(pid, 15_000) do
      instance
    else
      _ -> AshSqlite.MultiTenancy.tenant_repo(__MODULE__, tenant, context)
    end
  end
end

defmodule Probe.CellRepo do
  use AshCell.Repo, otp_app: :probe
  def min_sqlite_version, do: %Version{major: 3, minor: 38, patch: 0}
end

defmodule Probe.CellMigrations do
  use AshCell.Migrator
  migration(1, "CREATE TABLE posts (id TEXT PRIMARY KEY, title TEXT)")
end

defmodule Probe.Post do
  @moduledoc false
  # One resource per repo, identical apart from the repo, because a resource names
  # its repo at compile time.
  defmacro __using__(repo: repo) do
    quote do
      use Ash.Resource, domain: Probe.Domain, data_layer: AshSqlite.DataLayer

      sqlite do
        table "posts"
        repo unquote(repo)
      end

      multitenancy do
        strategy :context
      end

      attributes do
        uuid_primary_key :id
        attribute :title, :string, public?: true
      end

      actions do
        default_accept :*
        defaults [:read, :create]
      end
    end
  end
end

defmodule Probe.FixedPost, do: use(Probe.Post, repo: Probe.FixedRepo)
defmodule Probe.PrPost, do: use(Probe.Post, repo: Probe.PrRepo)
defmodule Probe.LookupFirstPost, do: use(Probe.Post, repo: Probe.LookupFirstRepo)
defmodule Probe.CellPost, do: use(Probe.Post, repo: Probe.CellRepo)

defmodule Probe.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Probe.FixedPost
    resource Probe.PrPost
    resource Probe.LookupFirstPost
    resource Probe.CellPost
  end
end

defmodule Probe do
  @tenants for i <- 1..32, do: "t#{String.pad_leading(to_string(i), 2, "0")}"
  @runs 5

  @variants [
    fixed: {Probe.FixedRepo, Probe.FixedPost},
    lookup_first: {Probe.LookupFirstRepo, Probe.LookupFirstPost},
    pr: {Probe.PrRepo, Probe.PrPost},
    ash_cell: {Probe.CellRepo, Probe.CellPost}
  ]

  def run do
    Logger.configure(level: :warning)
    root = Path.join(System.tmp_dir!(), "ash_cell_tenant_supervisor_probe")
    File.rm_rf!(root)
    migrations = Path.join(root, "migrations")
    File.mkdir_p!(migrations)

    File.write!(Path.join(migrations, "1_create_posts.exs"), """
    defmodule Probe.Migrations.CreatePosts do
      use Ecto.Migration

      def change do
        create table(:posts, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :title, :text
        end
      end
    end
    """)

    start(root, migrations)
    warm()

    IO.puts("""

    ash_sqlite at PR #246 head, #{length(@tenants)} warm tenants per variant, one row each.
    #{System.schedulers_online()} schedulers online. µs per call, median of #{@runs} runs, with the
    fastest and slowest run in brackets. For concurrent runs, wall time / calls.
    """)

    report("A. tenant_repo/2 alone, 1 caller, 10,000 calls on one tenant", fn {repo, _} ->
      sequential(10_000, fn -> repo.tenant_repo("t01", %{type: :read}) end)
    end)

    report("B. tenant_repo/2 alone, 32 callers on 32 tenants, 50,000 calls each", fn {repo, _} ->
      concurrent(50_000, fn tenant -> repo.tenant_repo(tenant, %{type: :read}) end)
    end)

    report("C. Ash.read!/2, 1 caller, 2,000 reads on one tenant", fn {_, resource} ->
      sequential(2_000, fn -> Ash.read!(resource, tenant: "t01") end)
    end)

    report("D. Ash.read!/2, 32 callers on 32 tenants, 2,000 reads each", fn {_, resource} ->
      concurrent(2_000, fn tenant -> Ash.read!(resource, tenant: tenant) end)
    end)

    spawns()
  end

  defp start(root, migrations) do
    for tenant <- @tenants do
      path = Path.join([root, "fixed", tenant <> ".db"])
      File.mkdir_p!(Path.dirname(path))
      {:ok, pid} = Probe.FixedRepo.start_link(name: nil, database: path, pool_size: 1)

      Ecto.Adapters.SQL.query!(pid, "CREATE TABLE posts (id TEXT PRIMARY KEY, title TEXT)", [])
      Probe.Fixed.put(tenant, pid)
    end

    # The same pool size AshCell gives a cell, so the variants differ only in how
    # the instance is found.
    for repo <- [Probe.PrRepo, Probe.LookupFirstRepo] do
      Application.put_env(:probe, repo, pool_size: 1)

      {:ok, _} =
        Supervisor.start_link(
          [
            {repo, tenants: [dir: Path.join(root, inspect(repo)), migrations_path: migrations]}
          ],
          strategy: :one_for_one
        )
    end

    {:ok, _} =
      Supervisor.start_link(
        [
          {AshCell,
           repo: Probe.CellRepo,
           dir: Path.join(root, "ash_cell"),
           migrator: Probe.CellMigrations,
           max_resident: 64}
        ],
        strategy: :one_for_one
      )
  end

  defp warm do
    for {_, {_, resource}} <- @variants, tenant <- @tenants do
      Ash.create!(resource, %{title: "warm"}, tenant: tenant)
    end
  end

  defp report(title, measure) do
    IO.puts(title)

    for {name, variant} <- @variants do
      measure.(variant)

      samples = for _ <- 1..@runs, do: measure.(variant)

      IO.puts(
        "  #{String.pad_trailing(to_string(name), 13)} #{format(median(samples))} µs  " <>
          "(#{format(Enum.min(samples))}–#{format(Enum.max(samples))})"
      )
    end

    IO.puts("")
  end

  defp sequential(calls, fun) do
    {us, _} = :timer.tc(fn -> repeat(calls, fun) end)
    us / calls
  end

  # A loop rather than a comprehension, so the harness does not build a list of
  # every result while it is being timed.
  defp repeat(0, _fun), do: :ok

  defp repeat(n, fun) do
    fun.()
    repeat(n - 1, fun)
  end

  defp concurrent(calls_each, fun) do
    {us, _} =
      :timer.tc(fn ->
        @tenants
        |> Enum.map(fn tenant ->
          Task.async(fn -> repeat(calls_each, fn -> fun.(tenant) end) end)
        end)
        |> Task.await_many(:infinity)
      end)

    us / (calls_each * length(@tenants))
  end

  # Whether a warm call makes the supervisor spawn a `Tenant` that then fails to
  # register. `:gen.start` looks the name up before spawning, so it should not; the
  # cold tenants are the control that shows the trace sees a spawn when one happens.
  defp spawns do
    IO.puts("E. processes the tenant DynamicSupervisor spawns")

    for name <- [:lookup_first, :pr] do
      {repo, _} = @variants[name]
      supervisor = Process.whereis(Module.concat(repo, Tenants))

      warm = traced(supervisor, fn -> for _ <- 1..1_000, do: repo.tenant_repo("t01", %{}) end)

      cold =
        traced(supervisor, fn -> for i <- 1..3, do: repo.tenant_repo("cold#{i}", %{}) end)

      IO.puts(
        "  #{String.pad_trailing(to_string(name), 13)} #{warm} during 1,000 warm calls, " <>
          "#{cold} opening 3 cold tenants"
      )
    end
  end

  defp traced(pid, fun) do
    :erlang.trace(pid, true, [:procs])
    fun.()
    :erlang.trace(pid, false, [:procs])
    count_spawns(0)
  end

  defp count_spawns(n) do
    receive do
      {:trace, _, :spawn, _, _} -> count_spawns(n + 1)
      {:trace, _, _, _} -> count_spawns(n)
      {:trace, _, _, _, _} -> count_spawns(n)
    after
      200 -> n
    end
  end

  defp median(samples), do: samples |> Enum.sort() |> Enum.at(div(length(samples), 2))
  defp format(us), do: us |> Float.round(2) |> :erlang.float_to_binary(decimals: 2)
end

Probe.run()
