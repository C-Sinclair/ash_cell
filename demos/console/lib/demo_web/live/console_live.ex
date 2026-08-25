defmodule DemoWeb.ConsoleLive do
  @moduledoc """
  The demo console.

  Four panels, in the order that makes the argument:

    1. **Isolation** — the compliance evidence, produced from outside the app.
    2. **Fleet** — cells starting, hibernating, and holding their own keys.
    3. **Speed** — the same workload on both data layers.
    4. **Object store** — the bucket as durable home and as coordinator.
    5. **Deploy** — what a rolling deploy costs, and what draining saves.
    6. **Records** — ordinary CRUD, so the rest of the page means something.
  """
  use DemoWeb, :live_view

  alias Demo.{Benchmark, Evidence, Records, Seed}
  alias Demo.Global.Clinic

  @impl true
  def mount(_params, _session, socket) do
    clinics = Ash.read!(Clinic) |> Enum.sort_by(& &1.name)
    selected = List.first(clinics)

    {:ok,
     socket
     |> assign(clinics: clinics, selected: selected, busy: nil)
     |> assign(bench: nil, storm: nil, restore: nil, snapshot: nil)
     |> assign(deploy: nil, holders: %{})
     |> assign(editing: nil, form_error: nil, search: nil, search_term: "")
     |> load_selected()}
  end

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.clinics, &(&1.id == id))

    {:noreply,
     socket
     |> assign(selected: selected, bench: nil, storm: nil, restore: nil, snapshot: nil)
     |> load_selected()}
  end

  def handle_event("simulate_deploy", _, socket) do
    # Everything a real shutdown does, without stopping the VM: seal, warn the
    # holders so they can reconnect while this node can still answer, then
    # checkpoint, snapshot, release each lease, and close.
    before = AshCell.resident_cells()
    warned = Enum.sum(for t <- before, do: AshCell.Drain.warn_holders(t, 400))

    {:ok, report} = AshCell.drain(grace_ms: 400)

    # A real deploy would end here; the node is going away. The demo keeps
    # running, so unseal to stand in for the replacement node coming up.
    AshCell.Manager.unseal()

    {:noreply,
     socket
     |> assign(
       deploy: %{
         resident_before: length(before),
         warned: warned,
         drained: length(report.drained),
         failed: map_size(report.failed),
         duration_ms: report.duration_ms
       }
     )
     |> assign(holders: AshCell.Holders.fleet())
     |> load_selected()}
  end

  def handle_event("hold_cell", _, socket) do
    # Stands in for a clinician with the page open: a long-lived holder that a
    # drain has to warn rather than count as idle.
    tenant = socket.assigns.selected.id
    AshCell.bind_held(tenant)

    {:noreply, assign(socket, holders: AshCell.Holders.fleet())}
  end

  def handle_event("release_cell", _, socket) do
    AshCell.release_held(socket.assigns.selected.id)
    {:noreply, assign(socket, holders: AshCell.Holders.fleet())}
  end

  def handle_event("save_patient", %{"patient" => params}, socket) do
    tenant = socket.assigns.selected.id

    result =
      case socket.assigns.editing do
        nil -> Records.create_patient(tenant, params)
        %{} = patient -> Records.update_patient(tenant, patient, params)
      end

    case result do
      {:ok, _patient} ->
        {:noreply,
         socket
         |> assign(editing: nil, form_error: nil)
         |> load_selected()}

      {:error, error} ->
        {:noreply, assign(socket, form_error: readable(error))}
    end
  end

  def handle_event("edit_patient", %{"id" => id}, socket) do
    patient = Records.get_patient(socket.assigns.selected.id, id)
    {:noreply, assign(socket, editing: patient, form_error: nil)}
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, assign(socket, editing: nil, form_error: nil)}
  end

  def handle_event("delete_patient", %{"id" => id}, socket) do
    tenant = socket.assigns.selected.id

    case Records.get_patient(tenant, id) do
      {:ok, patient} -> Records.delete_patient(tenant, patient)
      _ -> :ok
    end

    {:noreply, socket |> assign(editing: nil) |> load_selected()}
  end

  def handle_event("search_all", %{"term" => term}, socket) when byte_size(term) > 0 do
    {micros, results} = :timer.tc(fn -> Records.search_everywhere(term) end)

    {:noreply,
     assign(socket,
       search_term: term,
       search: %{results: results, ms: Float.round(micros / 1000, 1)}
     )}
  end

  def handle_event("search_all", _, socket), do: {:noreply, assign(socket, search: nil)}

  def handle_event("benchmark", _, socket) do
    id = socket.assigns.selected.id

    # Warm both sides first. The first call to a cold cell includes activation and
    # migration, which is a real cost but not the one this panel is measuring.
    Benchmark.cell_deep_load(id)
    Benchmark.postgres_deep_load(id)

    cell = median(fn -> Benchmark.cell_deep_load(id) end)
    pg = median(fn -> Benchmark.postgres_deep_load(id) end)
    raw = median(fn -> Benchmark.postgres_raw_deep_load(id) end)

    {_, rows} = Benchmark.cell_deep_load(id)

    bench = %{
      cell_micros: cell,
      pg_micros: pg,
      raw_micros: raw,
      rows: length(rows),
      speedup: Float.round(pg / max(cell, 1), 1),
      cell_point: median(fn -> Benchmark.cell_point_read(id) end),
      pg_point: median(fn -> Benchmark.postgres_point_read(id) end)
    }

    {:noreply, socket |> assign(bench: bench) |> load_selected()}
  end

  def handle_event("storm", _, socket) do
    storm = Benchmark.write_storm(socket.assigns.selected.id, 500)
    {:noreply, socket |> assign(storm: storm) |> load_selected()}
  end

  def handle_event("replicate", _, socket) do
    case Evidence.replicate(socket.assigns.selected.id) do
      # Not errors: a fleet with no lease does not replicate, and a ship already in
      # flight will finish on its own. Only `:precondition_failed` means fenced.
      {:ok, :no_lease} ->
        {:noreply, put_flash(socket, :info, "This fleet has no lease, so nothing ships.")}

      {:ok, :in_flight} ->
        {:noreply,
         put_flash(socket, :info, "Already shipping; the snapshot in flight will finish.")}

      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Shipped txid #{result.txid} (#{bytes(result.bytes)}) to the bucket")
         |> load_selected()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Replication failed: #{inspect(reason)}")}
    end
  end

  def handle_event("inspect_snapshot", _, socket) do
    case Evidence.inspect_stored_snapshot(socket.assigns.selected.id) do
      {:ok, snapshot} -> {:noreply, assign(socket, snapshot: snapshot)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "No snapshot: #{inspect(reason)}")}
    end
  end

  def handle_event("destroy_restore", _, socket) do
    case Evidence.destroy_and_restore(socket.assigns.selected.id) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(restore: result)
         |> put_flash(:info, "Destroyed locally, restored txid #{result.txid} from the bucket")
         |> load_selected()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Restore failed: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke_key", _, socket) do
    Demo.Cells.Vault.revoke(socket.assigns.selected.id)

    {:noreply,
     socket
     |> put_flash(
       :error,
       "Key destroyed. This clinic's bytes remain on disk and are now permanently unreadable."
     )
     |> load_selected()}
  end

  def handle_event("delete_clinic", _, socket) do
    {:ok, result} = Evidence.delete_clinic(socket.assigns.selected.id)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{length(result.removed)} files. No vacuum, no tombstones.")
     |> load_selected()}
  end

  def handle_event("close_cell", _, socket) do
    AshCell.close(socket.assigns.selected.id)
    {:noreply, socket |> put_flash(:info, "Cell hibernated. Data untouched.") |> load_selected()}
  end

  def handle_event("reseed", _, socket) do
    Seed.run(patients: 60)
    {:noreply, socket |> put_flash(:info, "Fleet reseeded.") |> load_selected()}
  end

  defp load_selected(socket) do
    id = socket.assigns.selected.id

    counts =
      try do
        Benchmark.count_rows(id)
      rescue
        _ -> %{"patients" => 0, "encounters" => 0, "observations" => 0}
      end

    assign(socket,
      counts: counts,
      evidence: Evidence.encryption_report(id),
      hexdump: elem_or(Evidence.hexdump(id, 192), "(unavailable)"),
      objects: Evidence.stored_objects(id),
      resident: AshCell.resident_cells(),
      patients: safe_patients(id),
      patient_total: safe_count(id),
      fleet: AshCell.fleet()
    )
  end

  defp elem_or({:ok, value}, _default), do: value
  defp elem_or(_, default), do: default

  defp bytes(n) when n > 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp bytes(n) when n > 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp bytes(n), do: "#{n} B"

  defp micros(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)} ms"
  defp micros(n), do: "#{n} µs"

  # A cell whose key was destroyed cannot be opened, and the records panel should
  # say so rather than take the page down with it.
  defp safe_patients(tenant) do
    Records.list_patients(tenant)
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp safe_count(tenant) do
    Records.count_patients(tenant)
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp readable(%{errors: errors}) when is_list(errors) do
    errors |> Enum.map_join("; ", &Exception.message/1)
  end

  defp readable(error), do: Exception.message(error)

  defp median(fun) do
    1..5
    |> Enum.map(fn _ -> elem(fun.(), 0) end)
    |> Enum.sort()
    |> Enum.at(2)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100 p-6 font-sans">
      <header class="mb-6">
        <h1 class="text-2xl font-semibold">AshCell — clinical console</h1>
        <p class="text-slate-400 text-sm mt-1">
          Every clinic is its own encrypted SQLite database, replicated to an object store.
          The global registry is Postgres. Nothing below asks you to take the app's word for anything.
        </p>
      </header>

      <div class="flex gap-3 mb-6 flex-wrap">
        <button
          :for={clinic <- @clinics}
          phx-click="select"
          phx-value-id={clinic.id}
          class={[
            "px-3 py-2 rounded text-sm border transition",
            if(clinic.id == @selected.id,
              do: "bg-emerald-600 border-emerald-400",
              else: "bg-slate-900 border-slate-700 hover:border-slate-500"
            )
          ]}
        >
          {clinic.name}
          <span :if={clinic.id in @resident} class="ml-2 text-emerald-300">●</span>
        </button>
        <button
          phx-click="reseed"
          class="px-3 py-2 rounded text-sm bg-slate-800 border border-slate-700"
        >
          Reseed fleet
        </button>
      </div>

      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <!-- 1. ISOLATION -->
        <section class="bg-slate-900 rounded-lg p-5 border border-slate-800">
          <h2 class="text-lg font-semibold mb-1">1 · Isolation, physically</h2>
          <p class="text-slate-400 text-sm mb-4">
            This clinic's data is a separate file with its own key, not a <code>WHERE</code> clause.
          </p>

          <dl class="grid grid-cols-2 gap-2 text-sm mb-4">
            <dt class="text-slate-400">File</dt>
            <dd class="font-mono text-xs break-all">{@evidence[:path]}</dd>
            <dt class="text-slate-400">Size</dt>
            <dd>{bytes(@evidence[:size] || 0)}</dd>
            <dt class="text-slate-400">Key fingerprint</dt>
            <dd class="font-mono text-xs">{@evidence[:key_fingerprint] || "— revoked —"}</dd>
            <dt class="text-slate-400">SQLite header present</dt>
            <dd class={if @evidence[:sqlite_header?], do: "text-red-400", else: "text-emerald-400"}>
              {if @evidence[:sqlite_header?], do: "yes — NOT encrypted", else: "no — encrypted"}
            </dd>
            <dt class="text-slate-400">Plaintext names on disk</dt>
            <dd class={
              if (@evidence[:plaintext_hits] || 0) > 0, do: "text-red-400", else: "text-emerald-400"
            }>
              {@evidence[:plaintext_hits] || 0}
            </dd>
          </dl>

          <pre class="bg-black rounded p-3 text-[10px] leading-tight overflow-x-auto text-emerald-300 mb-4">{@hexdump}</pre>

          <div class="flex gap-2 flex-wrap">
            <button
              phx-click="revoke_key"
              class="px-3 py-2 rounded text-sm bg-amber-700 hover:bg-amber-600"
            >
              Destroy this clinic's key
            </button>
            <button
              phx-click="delete_clinic"
              class="px-3 py-2 rounded text-sm bg-red-800 hover:bg-red-700"
            >
              Delete clinic (rm)
            </button>
            <button
              phx-click="close_cell"
              class="px-3 py-2 rounded text-sm bg-slate-800 border border-slate-700"
            >
              Hibernate cell
            </button>
          </div>
        </section>
        
    <!-- 2. FLEET -->
        <section class="bg-slate-900 rounded-lg p-5 border border-slate-800">
          <h2 class="text-lg font-semibold mb-1">2 · The fleet</h2>
          <p class="text-slate-400 text-sm mb-4">
            Cells start on demand and hibernate when idle. Residency is bounded; the data is a file and stays put.
          </p>

          <div class="text-sm mb-4">
            <div class="flex justify-between border-b border-slate-800 py-1 text-slate-400">
              <span>Resident cells</span><span>{length(@resident)}</span>
            </div>
            <div :for={cell <- @fleet} class="flex justify-between border-b border-slate-800/50 py-1">
              <span class="font-mono text-xs">{cell.cell_key}</span>
              <span class="text-slate-400 text-xs">
                {bytes(cell.bytes)} · {cell.queries} queries · resident {div(cell.resident_ms, 1000)}s
              </span>
            </div>
          </div>

          <h3 class="text-sm font-semibold text-slate-300 mt-4 mb-2">Rows in this cell</h3>
          <div class="grid grid-cols-3 gap-2 text-center">
            <div
              :for={{table, count} <- @counts}
              class="bg-slate-950 rounded p-3 border border-slate-800"
            >
              <div class="text-xl font-semibold">{count}</div>
              <div class="text-xs text-slate-400">{table}</div>
            </div>
          </div>

          <h3 class="text-sm font-semibold text-slate-300 mt-4 mb-2">Global registry (Postgres)</h3>
          <p class="text-xs text-slate-400">
            {length(@clinics)} clinics. The registry has to be global — you must list clinics
            before you know which cell to open.
          </p>
        </section>
        
    <!-- 3. SPEED -->
        <section class="bg-slate-900 rounded-lg p-5 border border-slate-800">
          <h2 class="text-lg font-semibold mb-1">3 · Speed, fairly measured</h2>
          <p class="text-slate-400 text-sm mb-4">
            Three-level load: patients → encounters → observations. Postgres holds identical
            data, indexed, warm pool, hand-written SQL.
          </p>

          <div class="flex gap-2 mb-4">
            <button
              phx-click="benchmark"
              class="px-3 py-2 rounded text-sm bg-emerald-700 hover:bg-emerald-600"
            >
              Run deep load on both
            </button>
            <button
              phx-click="storm"
              class="px-3 py-2 rounded text-sm bg-slate-800 border border-slate-700"
            >
              Write 500 rows
            </button>
          </div>

          <div :if={@bench} class="text-sm">
            <div class="grid grid-cols-3 gap-2 mb-3 text-center">
              <div class="bg-slate-950 rounded p-3 border border-emerald-800">
                <div class="text-xl font-semibold text-emerald-400">{micros(@bench.cell_micros)}</div>
                <div class="text-xs text-slate-400">AshCell<br />Ash + SQLite</div>
              </div>
              <div class="bg-slate-950 rounded p-3 border border-slate-700">
                <div class="text-xl font-semibold">{micros(@bench.pg_micros)}</div>
                <div class="text-xs text-slate-400">Postgres<br />Ash + Postgres</div>
              </div>
              <div class="bg-slate-950 rounded p-3 border border-slate-700">
                <div class="text-xl font-semibold">{micros(@bench.raw_micros)}</div>
                <div class="text-xs text-slate-400">Postgres<br />raw SQL, no framework</div>
              </div>
            </div>
            <p class="text-xs text-slate-300">
              {@bench.speedup}× faster than the same Ash query on Postgres, over {@bench.rows} patients
              and their full encounter/observation graph. Median of five, both sides warmed.
            </p>
            <p class="text-xs text-slate-400 mt-2">
              The third column is the one that matters: AshCell going through the whole framework
              lands level with hand-written SQL, because the framework cost is no longer hidden
              behind a network round trip. Point read: {micros(@bench.cell_point)} vs {micros(
                @bench.pg_point
              )}.
            </p>
          </div>

          <div :if={@storm} class="mt-4 text-sm bg-slate-950 rounded p-3 border border-slate-800">
            <div>
              {@storm.count} writes in {micros(@storm.micros)} — {@storm.per_second}/sec, {micros(
                @storm.per_write_micros
              )} each
            </div>
            <p class="text-xs text-amber-400 mt-2">
              Local fsync only. A durable configuration adds a round trip to the object store
              per commit, so this is not the write latency you would ship.
            </p>
          </div>
        </section>
        
    <!-- 4. OBJECT STORE -->
        <section class="bg-slate-900 rounded-lg p-5 border border-slate-800">
          <h2 class="text-lg font-semibold mb-1">4 · The object store</h2>
          <p class="text-slate-400 text-sm mb-4">
            The bucket is both the durable home for a cell and the coordinator that decides
            who owns it, via conditional writes.
          </p>

          <div class="flex gap-2 mb-4 flex-wrap">
            <button
              phx-click="replicate"
              class="px-3 py-2 rounded text-sm bg-sky-800 hover:bg-sky-700"
            >
              Ship to bucket
            </button>
            <button
              phx-click="inspect_snapshot"
              class="px-3 py-2 rounded text-sm bg-slate-800 border border-slate-700"
            >
              Fetch it back
            </button>
            <button
              phx-click="destroy_restore"
              class="px-3 py-2 rounded text-sm bg-red-900 hover:bg-red-800"
            >
              Destroy locally &amp; restore
            </button>
          </div>

          <div class="text-sm mb-3">
            <div class="text-slate-400 text-xs mb-1">Objects held for this clinic</div>
            <div :if={@objects == []} class="text-slate-500 text-xs">none yet</div>
            <div :for={key <- @objects} class="font-mono text-[11px] text-slate-300">{key}</div>
          </div>

          <div :if={@snapshot} class="bg-slate-950 rounded p-3 border border-slate-800 text-sm">
            <div class="grid grid-cols-2 gap-1 text-xs mb-2">
              <span class="text-slate-400">Txid</span><span>{@snapshot.txid}</span>
              <span class="text-slate-400">ETag</span><span class="font-mono">{@snapshot.etag}</span>
              <span class="text-slate-400">Size</span><span>{bytes(@snapshot.size)}</span>
              <span class="text-slate-400">Plaintext in stored bytes</span>
              <span class={
                if @snapshot.plaintext_hits > 0, do: "text-red-400", else: "text-emerald-400"
              }>
                {@snapshot.plaintext_hits}
              </span>
            </div>
            <pre class="bg-black rounded p-2 text-[10px] leading-tight overflow-x-auto text-sky-300">{@snapshot.head}</pre>
          </div>

          <div
            :if={@restore}
            class="mt-3 bg-emerald-950 rounded p-3 border border-emerald-800 text-sm"
          >
            Restored txid {@restore.txid} ({bytes(@restore.bytes)}) after deleting the local file.
            <div class="text-xs text-slate-300 mt-1">
              Rows back: {inspect(@restore.counts)}
            </div>
          </div>
        </section>
        
    <!-- 6. RECORDS -->
        <section class="bg-slate-900 rounded-lg p-5 border border-slate-800">
          <h2 class="text-lg font-semibold mb-1">6 · Records</h2>
          <p class="text-slate-400 text-sm mb-4">
            Real patients in <span class="text-slate-200">{@selected.name}</span>'s own database.
            No <code class="text-xs">clinic_id</code> column and no filter — writes land in this
            clinic's file because that is the file that is open.
          </p>

          <form phx-submit="save_patient" class="grid grid-cols-2 gap-2 mb-3">
            <input
              type="text"
              name="patient[name]"
              placeholder="Patient name"
              required
              value={@editing && @editing.name}
              class="col-span-2 bg-slate-950 border border-slate-700 rounded px-2 py-1.5 text-sm"
            />
            <input
              type="text"
              name="patient[mrn]"
              placeholder="MRN"
              value={@editing && @editing.mrn}
              class="bg-slate-950 border border-slate-700 rounded px-2 py-1.5 text-sm"
            />
            <input
              type="number"
              name="patient[birth_year]"
              placeholder="Birth year"
              value={@editing && @editing.birth_year}
              class="bg-slate-950 border border-slate-700 rounded px-2 py-1.5 text-sm"
            />
            <div class="col-span-2 flex gap-2">
              <button
                type="submit"
                class="px-3 py-2 rounded text-sm bg-emerald-800 hover:bg-emerald-700"
              >
                {if @editing, do: "Save changes", else: "Add patient"}
              </button>
              <button
                :if={@editing}
                type="button"
                phx-click="cancel_edit"
                class="px-3 py-2 rounded text-sm bg-slate-800 border border-slate-700"
              >
                Cancel
              </button>
            </div>
          </form>

          <div :if={@form_error} class="mb-3 text-xs text-red-400">{@form_error}</div>

          <div :if={@patients == :unavailable} class="text-amber-400 text-sm">
            This clinic's database cannot be opened — its key was destroyed. The bytes are still
            on disk and permanently unreadable.
          </div>

          <div :if={@patients != :unavailable}>
            <div class="text-slate-400 text-xs mb-1">
              Showing {length(@patients)} of {@patient_total}
            </div>
            <div class="max-h-64 overflow-y-auto border border-slate-800 rounded">
              <table class="w-full text-sm">
                <tbody>
                  <tr :for={p <- @patients} class="border-b border-slate-800 last:border-0">
                    <td class="px-2 py-1.5">{p.name}</td>
                    <td class="px-2 py-1.5 text-slate-400 font-mono text-xs">{p.mrn}</td>
                    <td class="px-2 py-1.5 text-slate-400 text-xs">{p.birth_year}</td>
                    <td class="px-2 py-1.5 text-right whitespace-nowrap">
                      <button
                        phx-click="edit_patient"
                        phx-value-id={p.id}
                        class="text-sky-400 text-xs mr-2"
                      >
                        edit
                      </button>
                      <button
                        phx-click="delete_patient"
                        phx-value-id={p.id}
                        class="text-red-400 text-xs"
                      >
                        delete
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <form phx-submit="search_all" class="mt-4 flex gap-2">
            <input
              type="text"
              name="term"
              value={@search_term}
              placeholder="Find a name across every clinic"
              class="flex-1 bg-slate-950 border border-slate-700 rounded px-2 py-1.5 text-sm"
            />
            <button class="px-3 py-2 rounded text-sm bg-slate-800 border border-slate-700">
              Search all
            </button>
          </form>

          <div :if={@search} class="mt-3 bg-slate-950 rounded p-3 border border-slate-800">
            <div class="text-xs text-slate-400 mb-2">
              Opened {length(@search.results)} databases in turn — {@search.ms} ms. There is no
              query that spans cells; this is the real cost of the architecture.
            </div>
            <div :for={r <- @search.results} class="text-xs flex justify-between py-0.5">
              <span class="text-slate-300">{r.clinic}</span>
              <span class={if r.count > 0, do: "text-emerald-400", else: "text-slate-600"}>
                {r.count} match(es)
              </span>
            </div>
          </div>
        </section>
        
    <!-- 5. DEPLOY -->
        <section class="bg-slate-900 rounded-lg p-5 border border-slate-800">
          <h2 class="text-lg font-semibold mb-1">5 · The deploy</h2>
          <p class="text-slate-400 text-sm mb-4">
            A shared database moves no data when it deploys. This one moves all of it. Killed,
            a node leaves leases nobody released — locking every tenant out for a full TTL —
            and writes nobody shipped. Drained, it hands over.
          </p>

          <div class="flex gap-2 mb-4 flex-wrap">
            <button
              phx-click="hold_cell"
              class="px-3 py-2 rounded text-sm bg-slate-800 border border-slate-700"
            >
              Open a tab on this clinic
            </button>
            <button
              phx-click="release_cell"
              class="px-3 py-2 rounded text-sm bg-slate-800 border border-slate-700"
            >
              Close it
            </button>
            <button
              phx-click="simulate_deploy"
              class="px-3 py-2 rounded text-sm bg-amber-800 hover:bg-amber-700"
            >
              Deploy (drain the node)
            </button>
          </div>

          <div class="text-sm mb-3">
            <div class="text-slate-400 text-xs mb-1">
              Long-lived holders — a cell with one is never "idle", even between keystrokes
            </div>
            <div :if={@holders == %{}} class="text-slate-500 text-xs">none</div>
            <div :for={{tenant, count} <- @holders} class="font-mono text-[11px] text-slate-300">
              {tenant} — {count} holder(s)
            </div>
          </div>

          <div :if={@deploy} class="bg-slate-950 rounded p-3 border border-slate-800 text-sm">
            <div class="grid grid-cols-2 gap-1 text-xs">
              <span class="text-slate-400">Cells resident before</span><span>{@deploy.resident_before}</span>
              <span class="text-slate-400">Holders warned to reconnect</span><span>{@deploy.warned}</span>
              <span class="text-slate-400">Drained (leases released)</span>
              <span class="text-emerald-400">{@deploy.drained}</span>
              <span class="text-slate-400">Failed (leases kept)</span>
              <span class={if @deploy.failed > 0, do: "text-red-400", else: "text-slate-300"}>
                {@deploy.failed}
              </span>
              <span class="text-slate-400">Took</span><span>{@deploy.duration_ms} ms</span>
            </div>
            <p class="text-slate-500 text-xs mt-2 leading-relaxed">
              Ordering is load-bearing: snapshot ships <em>before</em> the lease is released. The
              other way round, a successor claims the tenant and resumes from an older
              generation while newer data is still only on the departing disk — correctly
              fenced, and silently lost. A drain that fails keeps its lease for the same reason.
            </p>
          </div>
        </section>
      </div>

      <footer class="mt-6 text-xs text-slate-500">
        Encryption is at rest only — the node holds the key in memory to serve queries.
        HIPAA does not require physical isolation; this is blast-radius reduction and
        per-tenant crypto-shredding, not a regulatory shortcut.
      </footer>
    </div>
    """
  end
end
