defmodule BranchWeb.ConsoleLive do
  @moduledoc """
  The control plane: provision a database, branch it, write to the branch, watch the
  origin not change, then promote or be refused.

  The screen is arranged around the claim rather than around the CRUD. The branch
  tree and the two SQL panes sit side by side because the point being made is a
  *comparison* — the same query against origin and branch returning different rows
  is the isolation proof, and it is worth nothing if the user has to navigate
  between them to see it.
  """
  use BranchWeb, :live_view

  alias Branch.{Catalog, Cells, Service}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       databases: Catalog.databases(),
       result: nil,
       error: nil,
       notice: nil,
       sql: "",
       compare: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    database = params["database"]
    branch = params["branch"]

    socket =
      socket
      |> assign(database: database, branch: branch)
      |> load_branches()
      |> load_history()

    {:noreply, socket}
  end

  @impl true
  def handle_event("provision", %{"name" => name}, socket) do
    case Service.provision(String.trim(name)) do
      {:ok, %{database: database}} ->
        {:noreply,
         socket
         |> assign(databases: Catalog.databases())
         |> put_notice("provisioned #{database} with a root branch `main`")
         |> push_patch(to: ~p"/#{database}/main")}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  def handle_event("branch", %{"name" => name, "from" => from}, socket) do
    from = parse_txid(from)

    case Service.create_branch(socket.assigns.database, socket.assigns.branch, name, from) do
      {:ok, record} ->
        {:noreply,
         socket
         |> put_notice(branch_notice(record))
         |> push_patch(to: ~p"/#{socket.assigns.database}/#{name}")}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  # Keeps @sql in step with the textarea, so "run on both" compares the statement the
  # user is looking at rather than the last one they submitted.
  def handle_event("typed", %{"sql" => sql}, socket) do
    {:noreply, assign(socket, sql: sql)}
  end

  def handle_event("run", %{"sql" => sql}, socket) do
    %{database: database, branch: branch} = socket.assigns

    case Service.query(database, branch, sql) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(sql: sql, result: result, error: nil)
         |> load_history()}

      {:error, message} ->
        {:noreply, assign(socket, sql: sql, result: nil, error: message)}
    end
  end

  # Runs the same statement against this branch and its parent, side by side. This
  # is the isolation claim, and it is the one thing on the page that is worth more
  # than the sum of its two halves.
  def handle_event("compare", %{"sql" => sql}, socket) do
    %{database: database, branch: branch} = socket.assigns
    row = Catalog.branch(database, branch)

    case row && row.parent do
      nil ->
        {:noreply, put_error(socket, :root_branch)}

      parent ->
        {:noreply,
         assign(socket,
           sql: sql,
           compare: %{
             parent: parent,
             here: Service.query(database, branch, sql),
             there: Service.query(database, parent, sql)
           }
         )}
    end
  end

  def handle_event("snapshot", _params, socket) do
    case Service.snapshot(socket.assigns.database, socket.assigns.branch) do
      {:ok, %{txid: txid}} ->
        {:noreply, socket |> put_notice("shipped txid #{txid}") |> load_history()}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  def handle_event("merge", _params, socket) do
    case Service.merge(socket.assigns.database, socket.assigns.branch) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_notice("fast-forwarded, shipped as txid #{result.txid}")
         |> load_branches()
         |> load_history()}

      {:error, reason} ->
        {:noreply, socket |> put_error(reason) |> load_branches()}
    end
  end

  def handle_event("drop", %{"name" => name}, socket) do
    case Service.drop_branch(socket.assigns.database, name) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_notice("dropped #{name}")
         |> assign(
           branch: if(socket.assigns.branch == name, do: nil, else: socket.assigns.branch)
         )
         |> load_branches()}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  defp load_branches(%{assigns: %{database: nil}} = socket), do: assign(socket, branches: [])

  defp load_branches(socket),
    do: assign(socket, branches: Catalog.branches(socket.assigns.database))

  defp load_history(%{assigns: %{database: nil}} = socket), do: assign(socket, history: [])
  defp load_history(%{assigns: %{branch: nil}} = socket), do: assign(socket, history: [])

  defp load_history(socket) do
    case Service.history(socket.assigns.database, socket.assigns.branch) do
      {:ok, history} -> assign(socket, history: history)
      {:error, _} -> assign(socket, history: [])
    end
  end

  defp parse_txid(""), do: :latest
  defp parse_txid("latest"), do: :latest

  defp parse_txid(value) do
    case Integer.parse(value) do
      {txid, ""} -> txid
      _ -> :latest
    end
  end

  defp branch_notice(record) do
    base = "branched from txid #{record.from_txid}"

    if record.exact?,
      do: base,
      else: base <> " (asked for #{record.requested_txid}; resolved down to the nearest snapshot)"
  end

  defp put_notice(socket, message), do: assign(socket, notice: message, error: nil)
  defp put_error(socket, reason), do: assign(socket, error: describe(reason), notice: nil)

  # A refusal is the most interesting thing this demo does, so it gets a real
  # sentence rather than an inspected tuple.
  defp describe({:not_fast_forward, %{origin_digest: origin, branch_forked_at: forked}}) do
    """
    Refused: the parent has been written to since this branch was cut, so a \
    fast-forward would discard those writes. There is no correct automatic merge of \
    two diverged SQLite databases — re-branch from the parent's current head and \
    re-apply your change. (parent now #{short(origin)}, branch cut at #{short(forked)})\
    """
  end

  defp describe(:not_owner),
    do: "Refused: this node does not hold the parent's lease, so it must not write its file."

  defp describe(:root_branch), do: "This is a root branch: it has no parent to merge into."
  defp describe(:branch_exists), do: "A branch with that name already exists."
  defp describe(:no_such_branch), do: "No such branch."
  defp describe({:key_in_use, _}), do: "That cell key is already in use."
  defp describe(%Ecto.Changeset{}), do: "A database with that name already exists."
  defp describe(:not_found), do: "That branch has never shipped, so there is nothing to cut from."
  defp describe(other), do: inspect(other)

  defp short(nil), do: "—"
  defp short(digest), do: String.slice(digest, 0, 8)

  defp fmt_bytes(nil), do: "—"
  defp fmt_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp fmt_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp fmt_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      :if={@notice}
      class="mb-4 rounded border border-emerald-800 bg-emerald-950 px-4 py-2 text-sm text-emerald-200"
    >
      {@notice}
    </div>
    <div
      :if={@error}
      class="mb-4 rounded border border-amber-800 bg-amber-950 px-4 py-3 text-sm text-amber-200"
    >
      {@error}
    </div>

    <div class="grid grid-cols-12 gap-6">
      <aside class="col-span-3 space-y-6">
        <section>
          <h2 class="mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-500">Databases</h2>
          <ul class="space-y-1 text-sm">
            <li :for={db <- @databases}>
              <.link
                patch={~p"/#{db.name}/main"}
                class={[
                  "block rounded px-2 py-1",
                  (db.name == @database && "bg-zinc-800 text-zinc-100") ||
                    "text-zinc-400 hover:bg-zinc-900"
                ]}
              >
                {db.name}
              </.link>
            </li>
          </ul>
          <form phx-submit="provision" class="mt-3 flex gap-2">
            <input
              name="name"
              placeholder="new database"
              required
              class="w-full rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-sm text-zinc-100"
            />
            <button class="rounded bg-zinc-100 px-3 py-1 text-sm font-medium text-zinc-900">+</button>
          </form>
        </section>

        <section :if={@database}>
          <h2 class="mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-500">
            Branches of {@database}
          </h2>
          <ul class="space-y-1 text-sm">
            <li :for={b <- @branches} class="flex items-center justify-between gap-2">
              <.link
                patch={~p"/#{@database}/#{b.name}"}
                class={[
                  "flex-1 truncate rounded px-2 py-1",
                  (b.name == @branch && "bg-zinc-800 text-zinc-100") ||
                    "text-zinc-400 hover:bg-zinc-900"
                ]}
              >
                <span :if={b.parent} class="text-zinc-600">{b.parent} →</span>{b.name}
                <span :if={b.status == "merged"} class="ml-1 text-xs text-emerald-500">merged</span>
              </.link>
              <button
                :if={b.parent}
                phx-click="drop"
                phx-value-name={b.name}
                class="text-xs text-zinc-600 hover:text-red-400"
              >
                drop
              </button>
            </li>
          </ul>
        </section>

        <section :if={@branch}>
          <h2 class="mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-500">
            Snapshots
          </h2>
          <p class="mb-2 text-xs text-zinc-600">
            A branch can only be cut from a point that has shipped.
          </p>
          <ul class="space-y-1 font-mono text-xs text-zinc-400">
            <li :for={s <- @history} class="flex justify-between">
              <span>txid {s.txid}</span>
              <span class="text-zinc-600">{fmt_bytes(s.bytes)}</span>
            </li>
            <li :if={@history == []} class="text-zinc-600">none yet</li>
          </ul>
          <button
            phx-click="snapshot"
            class="mt-3 w-full rounded border border-zinc-700 px-2 py-1 text-xs text-zinc-300 hover:bg-zinc-900"
          >
            Snapshot now
          </button>
        </section>
      </aside>

      <section :if={@branch} class="col-span-9 space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="font-mono text-lg text-zinc-100">{Cells.key(@database, @branch)}</h1>
            <p class="text-xs text-zinc-500">
              one encrypted SQLite file, one writer, its own lease and txid namespace
            </p>
          </div>
          <button
            :if={@branch != "main"}
            phx-click="merge"
            class="rounded bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-500"
          >
            Merge into parent
          </button>
        </div>

        <form phx-submit="run" phx-change="typed" class="space-y-2">
          <textarea
            name="sql"
            rows="4"
            placeholder="CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);"
            class="w-full rounded border border-zinc-700 bg-zinc-900 p-3 font-mono text-sm text-zinc-100"
          >{@sql}</textarea>
          <div class="flex gap-2">
            <button class="rounded bg-zinc-100 px-4 py-1.5 text-sm font-medium text-zinc-900">
              Run
            </button>
            <button
              type="button"
              phx-click="compare"
              phx-value-sql={@sql}
              class="rounded border border-zinc-700 px-4 py-1.5 text-sm text-zinc-300 hover:bg-zinc-900"
            >
              Run on both, side by side
            </button>
          </div>
        </form>

        <div :if={@result} class="overflow-x-auto rounded border border-zinc-800">
          <table class="w-full text-left font-mono text-xs">
            <thead class="bg-zinc-900 text-zinc-400">
              <tr>
                <th :for={c <- @result.columns} class="px-3 py-2">{c}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @result.rows} class="border-t border-zinc-800 text-zinc-200">
                <td :for={cell <- row} class="px-3 py-1.5">{inspect(cell)}</td>
              </tr>
            </tbody>
          </table>
          <p class="border-t border-zinc-800 px-3 py-1.5 text-xs text-zinc-500">
            {@result.count} row(s)
          </p>
        </div>

        <div :if={@compare} class="grid grid-cols-2 gap-4">
          <.pane title={"this branch — " <> @branch} result={@compare.here} />
          <.pane title={"parent — " <> @compare.parent} result={@compare.there} />
        </div>

        <section class="rounded border border-zinc-800 p-4">
          <h2 class="mb-2 text-xs font-semibold uppercase tracking-wider text-zinc-500">
            Cut a branch from here
          </h2>
          <form phx-submit="branch" class="flex gap-2">
            <input
              name="name"
              placeholder="branch name"
              required
              class="flex-1 rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-sm text-zinc-100"
            />
            <input
              name="from"
              placeholder="txid (blank = latest)"
              class="w-48 rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-sm text-zinc-100"
            />
            <button class="rounded bg-zinc-100 px-4 py-1 text-sm font-medium text-zinc-900">
              Branch
            </button>
          </form>
        </section>
      </section>

      <section :if={is_nil(@branch)} class="col-span-9 text-sm text-zinc-400">
        <p>Provision a database, or pick one, to begin.</p>
      </section>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :result, :any, required: true

  defp pane(assigns) do
    ~H"""
    <div class="rounded border border-zinc-800">
      <p class="border-b border-zinc-800 bg-zinc-900 px-3 py-1.5 font-mono text-xs text-zinc-400">
        {@title}
      </p>
      <%= case @result do %>
        <% {:ok, result} -> %>
          <table class="w-full text-left font-mono text-xs">
            <thead class="text-zinc-500">
              <tr>
                <th :for={c <- result.columns} class="px-3 py-1.5">{c}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- result.rows} class="border-t border-zinc-800 text-zinc-200">
                <td :for={cell <- row} class="px-3 py-1">{inspect(cell)}</td>
              </tr>
            </tbody>
          </table>
        <% {:error, message} -> %>
          <p class="px-3 py-2 font-mono text-xs text-amber-400">{message}</p>
      <% end %>
    </div>
    """
  end
end
