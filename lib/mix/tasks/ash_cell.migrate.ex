defmodule Mix.Tasks.AshCell.Migrate do
  @shortdoc "Migrates every cell in the fleet, eagerly"

  @moduledoc """
  Activates and migrates each named tenant.

      mix ash_cell.migrate --tenants acme,globex
      mix ash_cell.migrate --tenants-from priv/tenants.txt

  Lazy migration works, but it fails one tenant at a time at whatever hour that
  tenant next wakes up. Running this at deploy time surfaces the same failures
  while someone is watching, which is the difference between a migration bug and
  an unattended outage.

  Exits non-zero if any tenant fails, so a deploy can gate on it.
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [tenants: :string, tenants_from: :string, keep_open: :boolean]
      )

    Mix.Task.run("app.start")

    tenants = tenants(opts)

    if tenants == [] do
      Mix.raise("no tenants given — pass --tenants a,b or --tenants-from FILE")
    end

    results = AshCell.Manager.migrate_all(tenants, close_after?: !opts[:keep_open])

    for {tenant, result} <- results do
      case result do
        {:ok, version} -> Mix.shell().info("  ok      #{tenant} → schema #{version}")
        {:error, reason} -> Mix.shell().error("  FAILED  #{tenant} — #{inspect(reason)}")
      end
    end

    failed = Enum.count(results, &match?({_, {:error, _}}, &1))

    Mix.shell().info("\n#{length(results) - failed} migrated, #{failed} failed")

    if failed > 0, do: exit({:shutdown, 1})
  end

  defp tenants(opts) do
    cond do
      opts[:tenants] -> String.split(opts[:tenants], ",", trim: true)
      opts[:tenants_from] -> opts[:tenants_from] |> File.read!() |> String.split("\n", trim: true)
      true -> []
    end
  end
end
