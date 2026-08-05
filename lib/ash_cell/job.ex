defmodule AshCell.Job do
  @moduledoc """
  Carrying tenant context into background work.

  ## The problem

  Request-level routing has a request to route. Background work does not: an Oban
  job runs on whichever node polled the queue, in a fresh process, with no
  binding. And because Ecto's binding is a process-dictionary entry, an unbound
  job does not obviously misbehave — it reaches for the repo *module*, which in a
  cell deployment was never started, so it fails somewhere deep in Ecto with a
  message about pools.

  ## Why it is nonetheless straightforward

  The handle is the tenant id, not a pid (see `AshCell`). A tenant id is an
  ordinary term: it serialises into job args, survives a restart, and means the
  same thing on another node. So a job does not need to *inherit* anything — it
  needs to *carry* the tenant and bind for itself:

      defmodule MyApp.RecalculateRisk do
        use Oban.Worker, queue: :default
        use AshCell.Job

        @impl AshCell.Job
        def perform_for_tenant(tenant, %Oban.Job{args: args}) do
          MyApp.Patient |> Ash.read!(tenant: tenant)
        end
      end

  `use AshCell.Job` defines `perform/1`, pulls `"tenant"` out of the job args,
  binds the cell, and calls `perform_for_tenant/2`. Enqueue with the tenant in the
  args and there is nothing else to remember:

      %{tenant: "acme", patient_id: id} |> MyApp.RecalculateRisk.new() |> Oban.insert()

  `enqueue/3` does that for you and refuses a job with no tenant, which is the
  point: the failure happens where the job is created, not at 3am inside a worker.

  ## The same shape works for anything

  `AshCell.Job.run/2` is the general form for a `Task`, a consumer, a `handle_info`,
  or any other place work arrives without a request. There is no magic in the Oban
  version beyond argument plumbing.

  ## What this deliberately does not do

  It does not route the job to whichever node owns the cell. The job binds a cell
  *on its own node*, which is correct for a single-writer deployment only if
  ownership has already been resolved there. Under multi-node placement a job must
  either run where the lease is held or acquire it, and that is placement's
  problem, not this module's — see the lease documentation.
  """

  @doc "Runs the job's real work with the tenant already bound."
  @callback perform_for_tenant(tenant :: term(), job :: term()) ::
              :ok | {:ok, term()} | {:error, term()} | {:cancel, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour AshCell.Job

      @impl Oban.Worker
      def perform(%{args: args} = job) do
        AshCell.Job.run(args, fn tenant -> perform_for_tenant(tenant, job) end)
      end

      defoverridable perform: 1
    end
  end

  @doc """
  Binds the tenant named in `args` and runs `fun`.

  Accepts `"tenant"` or `:tenant`, since job args round-trip through JSON and come
  back with string keys.

  A job with no tenant is cancelled rather than retried: it will never succeed, so
  retrying it just fills the queue and hides the bug.
  """
  def run(args, fun) when is_function(fun, 1) do
    case fetch_tenant(args) do
      {:ok, tenant} -> AshCell.with_tenant(tenant, fn -> fun.(tenant) end)
      :error -> {:cancel, :missing_tenant}
    end
  end

  @doc """
  Builds job args with the tenant included, refusing to build them without one.

      MyApp.RecalculateRisk.new(AshCell.Job.args!("acme", %{patient_id: id}))
  """
  def args!(tenant, args \\ %{}) when not is_nil(tenant) do
    args |> Map.new() |> Map.put(:tenant, tenant)
  end

  @doc "The tenant in a set of job args, if any."
  def fetch_tenant(args) do
    case args do
      %{"tenant" => tenant} when not is_nil(tenant) -> {:ok, tenant}
      %{tenant: tenant} when not is_nil(tenant) -> {:ok, tenant}
      _ -> :error
    end
  end
end
