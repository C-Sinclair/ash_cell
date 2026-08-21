defmodule AshCell do
  @moduledoc """
  Database-per-tenant SQLite for Ash.

  Each tenant is a *cell*: one SQLite file, optionally encrypted with that tenant's
  own key, owned by one process, with compute routed to the data rather than the
  reverse.

  ## The handle is the tenant id, not a pid

  Ecto binds a repo *instance* per process, and `c:Ecto.Repo.put_dynamic_repo/1`
  accepts only an atom or a pid — via-tuples are rejected by its guard, and
  `Ecto.Repo.Registry.lookup/1` resolves an atom through `GenServer.whereis/1`.
  Neither is a good handle to pass around:

    * a **pid** is unstable across cell restarts and cannot be serialised into a
      job payload
    * an **atom name** is stable and serialisable, but atoms are never garbage
      collected, so minting one per tenant leaks the atom table

  So the portable handle is the **tenant id itself**. `AshCell.Registry` resolves
  it to a live cell, starting one if needed, and the pid never leaves `bind/1`.
  That is what makes this work from any context — a controller, a LiveView, a
  `Task`, or an Oban job on a different node — with nothing inherited.

      AshCell.with_tenant("acme", fn ->
        MyApp.Patient |> Ash.read!(tenant: "acme")
      end)

  ## Binding is ambient, so bind explicitly

  Because Ecto's binding lives in the process dictionary, it does **not** survive
  `Task.async`, `Ash.load` fan-out, or a job boundary. Every entry point must bind
  for itself. Nothing should ever rely on inheriting a binding, and
  `assert_bound!/0` exists to make that a loud failure rather than a quiet one.
  """

  @cell_key {__MODULE__, :bound_cell}

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, type: :supervisor, start: {AshCell.Supervisor, :start_link, [opts]}}
  end

  @doc """
  Binds the calling process to `tenant`'s database, starting the cell if needed.

  Returns the previous binding so it can be restored. Prefer `with_tenant/2`
  unless you genuinely need to hold a binding across calls — for example inside a
  GenServer that only ever serves one tenant.
  """
  @spec bind(term()) :: {:ok, term()} | {:error, term()}
  def bind(tenant), do: bind_key(AshCell.CellKey.resolve(tenant), 1)

  # A cell can die between being looked up and being asked for its repo pid --
  # evicted for inactivity, closed by a drain, or restarted after a crash. The
  # window is small and entirely normal, so a caller should not see an exit from
  # a GenServer it never knew about: resolve again and try once more.
  defp bind_key(cell_key, attempts_left) do
    with :ok <- await_not_closing(cell_key),
         {:ok, cell} <- AshCell.Manager.ensure_started(cell_key),
         {:ok, repo_pid} <- fetch_repo_pid(cell),
         :ok <- AshCell.Registry.bound(cell_key) do
      repo = repo()
      previous = {repo.get_dynamic_repo(), Process.get(@cell_key)}

      repo.put_dynamic_repo(repo_pid)
      Process.put(@cell_key, cell_key)
      AshCell.Cell.note_query(cell)

      {:ok, previous}
    else
      # The cell began closing between the check and the count. Undo and retry
      # against whatever replaces it.
      :closing when attempts_left > 0 ->
        bind_key(cell_key, attempts_left - 1)

      :closing ->
        {:error, :cell_closing}

      {:error, :cell_died} when attempts_left > 0 ->
        bind_key(cell_key, attempts_left - 1)

      {:error, :cell_died} ->
        {:error, :cell_unavailable}

      other ->
        other
    end
  end

  # Bounded, because a close that never completes must surface as an error rather
  # than blocking a request forever.
  defp await_not_closing(cell_key, attempts \\ 100) do
    cond do
      not AshCell.Registry.closing?(cell_key) -> :ok
      attempts == 0 -> {:error, :cell_closing}
      true -> Process.sleep(10) && await_not_closing(cell_key, attempts - 1)
    end
  end

  defp fetch_repo_pid(cell) do
    {:ok, AshCell.Cell.repo_pid(cell)}
  catch
    :exit, _ -> {:error, :cell_died}
  end

  @doc "Restores a binding returned by `bind/1`."
  @spec restore({term(), term()}) :: :ok
  def restore({dynamic_repo, tenant}) do
    # Release the binding this process currently holds before adopting the
    # previous one, so a nested with_tenant/2 decrements the inner tenant rather
    # than leaking a count that would make it look permanently busy to a drain.
    case Process.get(@cell_key) do
      nil -> :ok
      current -> AshCell.Registry.unbound(current)
    end

    repo().put_dynamic_repo(dynamic_repo)

    case tenant do
      nil -> Process.delete(@cell_key)
      other -> Process.put(@cell_key, other)
    end

    :ok
  end

  @doc """
  Binds `tenant` for a long-lived process and registers it as a holder.

  For processes that outlive a single unit of work — a LiveView, a per-tenant
  GenServer, a channel. Unlike `with_tenant/2` there is no matching release: the
  hold is cleaned up when the process dies, which is the only signal that reliably
  arrives when a browser tab closes.

  Call it before each piece of work rather than once at startup. The binding is a
  repo pid and the process outlives it: a cell that is evicted, restarted, or
  drained comes back as a new instance, and a binding taken once at startup then
  points at a dead one.
  """
  @spec bind_held(term()) :: :ok | {:error, term()}
  def bind_held(tenant) do
    cell_key = AshCell.CellKey.resolve(tenant)

    with {:ok, cell} <- AshCell.Manager.ensure_started(cell_key) do
      repo = repo()
      repo.put_dynamic_repo(AshCell.Cell.repo_pid(cell))
      Process.put(@cell_key, cell_key)
      AshCell.Holders.hold(cell_key)
      :ok
    end
  end

  @doc "Releases a hold taken with `bind_held/1`."
  @spec release_held(term()) :: :ok
  def release_held(tenant) do
    AshCell.Holders.release(AshCell.CellKey.resolve(tenant))
    Process.delete(@cell_key)
    repo().put_dynamic_repo(repo())
    :ok
  end

  @doc "Clears any tenant binding on this process."
  @spec unbind() :: :ok
  def unbind, do: restore({repo(), nil})

  @doc """
  Runs `fun` with the process bound to `tenant`'s database.

  Restores the previous binding afterwards, so nesting and re-entry are safe.
  """
  @spec with_tenant(term(), (-> result)) :: result when result: var
  def with_tenant(tenant, fun) when is_function(fun, 0) do
    {:ok, previous} = bind(tenant)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc """
  Runs `fun` inside a single transaction on `tenant`'s cell.

  Each Ash action already transacts on its own once a resource has
  `AshCell.Resource`, so this is for making *several* of them atomic together:

      AshCell.transaction("acme", fn ->
        {:ok, patient} = MyApp.Patient.create("Ada", tenant: "acme")
        {:ok, _} = MyApp.Visit.create(patient.id, tenant: "acme")
      end)

  Actions inside join this transaction rather than opening their own — Ash checks
  `c:Ash.DataLayer.in_transaction?/1` first and skips resources already in one.
  Returns `{:ok, result}` or `{:error, reason}`, like `c:Ecto.Repo.transaction/2`.
  Call `rollback/1` to abort.

  Opened as `BEGIN IMMEDIATE`, so the write lock is taken up front. A deferred
  transaction that reads and then writes has to upgrade its lock, and SQLite
  cannot make an upgrade wait — it fails immediately, regardless of
  `busy_timeout`.

  ## One cell per transaction

  A transaction lives on one connection and a cell is one file, so this cannot
  span tenants. SQLite can commit across `ATTACH`ed databases, but not when they
  are in WAL mode — and cells are, because replication needs the WAL. Nesting a
  different tenant raises rather than silently giving you two independent commits.
  """
  @spec transaction(term(), (-> result)) :: {:ok, result} | {:error, term()} when result: var
  def transaction(tenant, fun) when is_function(fun, 0) do
    assert_same_cell!(AshCell.CellKey.resolve(tenant))

    deferring_notifications(fn ->
      with_tenant(tenant, fn -> repo().transaction(fun, mode: :immediate) end)
    end)
  end

  # Compared as cell keys rather than as tenants, which is what makes this correct
  # under a resolver that is not the identity. Two tenants that resolve to one
  # cell -- adjacent dates in one monthly window, say -- are one connection and one
  # transaction, and refusing that would be wrong. Two tenants that resolve to two
  # cells are refused however similar they look.
  defp assert_same_cell!(cell_key) do
    current = bound_cell()

    if current && current != cell_key && in_transaction?() do
      raise ArgumentError, """
      cannot open a transaction on cell #{inspect(cell_key)} while one is open on \
      #{inspect(current)}.

      Each cell is a separate SQLite file with its own connection, so these \
      would be two independent transactions: the inner one would commit on its \
      own and survive a rollback of the outer. Finish one before opening the \
      other, and if the work genuinely spans cells, make that ordering explicit \
      rather than implicit in a nesting.
      """
    end

    :ok
  end

  # Mirrors what `Ash.transaction/3` does around a transaction it opens itself.
  # Ash defers notifications while one is open and expects whoever opened it to
  # flush them on commit; without this they are built, never sent, and Ash warns
  # about having missed them. `Ash.transaction/3` cannot just be delegated to,
  # because it hardcodes its transaction reason and so leaves no channel for the
  # tenant to reach the data layer.
  defp deferring_notifications(fun) do
    started? = !Process.put(:ash_started_transaction?, true)
    outer = Process.delete(:ash_notifications)

    try do
      fun.() |> tap(&flush_or_discard(&1, started?))
    after
      if started?, do: Process.delete(:ash_started_transaction?)
      if outer, do: Process.put(:ash_notifications, outer)
    end
  end

  defp flush_or_discard({:ok, _committed}, true), do: flush_notifications()
  defp flush_or_discard({:ok, _committed}, false), do: :ok

  # Rolled back, so the notifications describe writes that did not happen.
  defp flush_or_discard({:error, _rolled_back}, _started?), do: Process.delete(:ash_notifications)

  defp flush_notifications do
    (Process.delete(:ash_notifications) || [])
    |> Ash.Notifier.notify()
  end

  @doc """
  Aborts the transaction opened by `transaction/2`, which returns `{:error, term}`.
  """
  @spec rollback(term()) :: no_return()
  def rollback(term), do: repo().rollback(term)

  @doc """
  Whether this process is inside a transaction on the cell it is bound to.

  False when nothing is bound: a repo reached only through `put_dynamic_repo/1` is
  never started under its module name, and asking Ecto about it would raise
  rather than answer.
  """
  @spec in_transaction?() :: boolean()
  def in_transaction? do
    repo = repo()

    case repo.get_dynamic_repo() do
      pid when is_pid(pid) -> repo.in_transaction?()
      _unbound -> false
    end
  end

  @doc """
  The key of the cell bound to this process, or `nil`.

  This is the *cell key*, not the tenant it was resolved from. Under a resolver
  that maps several tenants to one cell — a time window, a workload split — the
  tenant is not recoverable from here, and the cell key is the thing every caller
  actually wants to compare.

  Read from the process dictionary rather than derived by searching the registry
  for a matching pid, so it stays correct when a cell restarts and gets a new pid.
  """
  @spec bound_cell() :: term() | nil
  def bound_cell, do: Process.get(@cell_key)

  @doc """
  Raises unless this process is bound to a tenant.

  Use at the top of anything that will run tenanted queries but did not itself
  establish the binding — a background job, a spawned task, a consumer. Without
  it, an unbound query fails deep inside Ecto with a message about the repo not
  being started, which is technically fail-closed but tells you nothing about why.
  """
  @spec assert_bound!() :: term()
  def assert_bound! do
    case bound_cell() do
      nil ->
        raise ArgumentError, """
        no AshCell tenant is bound to this process.

        The binding lives in the process dictionary and does not cross process
        boundaries, so a Task, an Oban job, or a spawned consumer starts unbound.
        Wrap the work:

            AshCell.with_tenant(tenant_id, fn -> ... end)
        """

      tenant ->
        tenant
    end
  end

  @doc """
  Folds the tenant's write-ahead log into its main database file.

  In WAL mode a committed row lives in `<db>-wal` until a checkpoint moves it, so
  the `.db` file on its own is not the whole database. Anything that inspects,
  copies, or ships the file — replication, export, or proving on-disk contents —
  must checkpoint first or it will silently miss recent writes.
  """
  def checkpoint(tenant) do
    with_tenant(tenant, fn ->
      {:ok, pid} = AshCell.Manager.ensure_started(tenant)
      repo_pid = AshCell.Cell.repo_pid(pid)
      Ecto.Adapters.SQL.query!(repo_pid, "PRAGMA wal_checkpoint(TRUNCATE)", [])
      :ok
    end)
  end

  @doc "Closes a tenant's cell, leaving its database on disk."
  defdelegate close(tenant), to: AshCell.Manager

  @doc "Closes a tenant's cell and deletes its database files."
  defdelegate delete(tenant), to: AshCell.Manager

  @doc "Absolute path of a tenant's database file."
  defdelegate path_for(tenant), to: AshCell.Manager

  @doc "Tenants with a resident (open) cell right now."
  defdelegate resident_cells(), to: AshCell.Registry

  @doc """
  Hands every resident cell over and releases its lease.

  Call before the node goes away. Runs automatically on supervised shutdown; see
  `AshCell.Drain` for why the ordering inside it matters.
  """
  defdelegate drain(opts \\ []), to: AshCell.Drain, as: :run

  @doc "Per-cell stats for the resident fleet."
  def fleet do
    for cell_key <- AshCell.Registry.resident_cells(),
        {:ok, pid} <- [AshCell.Registry.lookup(cell_key)] do
      AshCell.Cell.info(pid)
    end
  end

  @doc false
  def repo, do: AshCell.Manager.config().repo
end
