defmodule CollabEditorWeb.EditorLive do
  @moduledoc """
  The editor, and the whole of the server's part in collaboration.

  What this process does is narrow on purpose: it takes Yjs updates from one
  browser, hands them to `CollabEditor.Editing.append/3` to be stored in the
  document's cell, and pushes everyone else's stored updates back out. Awareness
  goes through it without being stored at all.

  It arbitrates nothing. Yjs merges, and the cell keeps the log — this is a relay
  with a durable middle.

  ## Binding

  `AshCell.LiveView`'s hook re-binds before every callback rather than once at
  mount, because the binding is a pid and a LiveView outlives its cell: eviction, a
  crash, or a drain gives the document a new repo instance, and a mount-time
  binding would point at a dead one during an ordinary keystroke. The hook also
  registers this LiveView as a *holder*, so a drain does not take a document out
  from under somebody who is typing in it.

  The tenant is the document id; `CollabEditor.CellKey` turns it into the cell.
  """
  use CollabEditorWeb, :live_view

  alias CollabEditor.{CellKey, Editing}
  alias CollabEditor.Cells.Vault
  alias CollabEditorWeb.Presence

  on_mount {__MODULE__, :tenant_from_params}
  on_mount {AshCell.LiveView, :bind_tenant}

  @doc false
  def on_mount(:tenant_from_params, %{"id" => id}, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :tenant, id)}
  end

  @impl true
  def mount(%{"id" => doc_id}, _session, socket) do
    client_id = Ash.UUID.generate()

    if connected?(socket) do
      Editing.subscribe(doc_id)

      {:ok, _} =
        Presence.track(self(), Editing.topic(doc_id), client_id, %{
          name: "guest-" <> binary_part(client_id, 0, 4)
        })
    end

    case Editing.state(doc_id) do
      {:ok, state} ->
        {:ok,
         socket
         |> assign(
           doc_id: doc_id,
           client_id: client_id,
           document: state.document,
           head: state.head,
           initial_state: Base.encode64(state.update),
           cell_key: CellKey.resolve(doc_id),
           fingerprint: Vault.fingerprint(CellKey.resolve(doc_id)),
           stats: Editing.stats(doc_id),
           peers: peers(doc_id)
         )}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "That document's cell could not be opened.")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("update", %{"update" => encoded}, socket) do
    {:ok, update} = Base.decode64(encoded)
    {:ok, seq} = Editing.append(socket.assigns.doc_id, update, socket.assigns.client_id)

    {:noreply, assign(socket, head: seq, stats: Editing.stats(socket.assigns.doc_id))}
  end

  def handle_event("awareness", %{"update" => encoded}, socket) do
    Editing.relay_awareness(socket.assigns.doc_id, encoded, socket.assigns.client_id)
    {:noreply, socket}
  end

  def handle_event("resume", %{"since" => since}, socket) do
    case Editing.updates_since(socket.assigns.doc_id, since) do
      {:ok, :compacted_past} ->
        # Compaction absorbed everything this client missed, so there is no tail to
        # replay. It gets the snapshot instead — correct rather than clever.
        {:ok, state} = Editing.state(socket.assigns.doc_id)

        {:noreply,
         push_event(socket, "reload", %{
           state: Base.encode64(state.update),
           head: state.head
         })}

      {:ok, updates} ->
        {:noreply,
         push_event(socket, "replay", %{
           updates: Enum.map(updates, &%{seq: &1.seq, update: Base.encode64(&1.update)})
         })}
    end
  end

  def handle_event("rename", %{"title" => title}, socket) do
    {:ok, document} = Editing.rename(socket.assigns.doc_id, title)
    {:noreply, assign(socket, document: document)}
  end

  def handle_event("compact", _params, socket) do
    {:ok, result} = Editing.compact(socket.assigns.doc_id)

    {:noreply,
     socket
     |> assign(stats: Editing.stats(socket.assigns.doc_id))
     |> put_flash(
       :info,
       "Merged #{result.merged} updates (#{result.log_bytes} bytes of log) into a " <>
         "#{result.snapshot_bytes}-byte snapshot through seq #{result.through_seq}."
     )}
  end

  def handle_event("checkpoint", _params, socket) do
    :ok = AshCell.checkpoint(socket.assigns.cell_key)

    {:noreply,
     socket
     |> assign(stats: Editing.stats(socket.assigns.doc_id))
     |> put_flash(:info, "Checkpointed: the WAL is folded into the file.")}
  end

  @impl true
  def handle_info(
        {:update, %{client_id: client_id}},
        %{assigns: %{client_id: client_id}} = socket
      ) do
    # Our own update, echoed back. Yjs would discard it as already applied, but not
    # sending it saves the round trip and the wasted decode.
    {:noreply, socket}
  end

  def handle_info({:update, %{seq: seq, update: update}}, socket) do
    {:noreply,
     socket
     |> push_event("remote_update", %{seq: seq, update: Base.encode64(update)})
     |> assign(head: seq, stats: Editing.stats(socket.assigns.doc_id))}
  end

  def handle_info(
        {:awareness, %{client_id: client_id}},
        %{assigns: %{client_id: client_id}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_info({:awareness, %{update: update}}, socket) do
    {:noreply, push_event(socket, "remote_awareness", %{update: update})}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, peers: peers(socket.assigns.doc_id))}
  end

  defp peers(doc_id) do
    doc_id
    |> Editing.topic()
    |> Presence.list()
    |> Enum.map(fn {_id, %{metas: [meta | _]}} -> meta.name end)
    |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-8 text-slate-100">
      <div class="flex items-baseline justify-between">
        <div>
          <.link navigate={~p"/"} class="text-sm text-slate-400 hover:underline">
            &larr; all documents
          </.link>
          <form phx-change="rename" class="mt-1">
            <input
              type="text"
              name="title"
              value={@document.title}
              phx-debounce="500"
              class="bg-transparent text-2xl font-semibold outline-none border-b border-transparent focus:border-slate-700"
            />
          </form>
        </div>
        <div class="text-right text-xs text-slate-400 space-y-1">
          <div>in this document: {Enum.join(@peers, ", ")}</div>
          <div>seq <span class="font-mono text-emerald-400">{@head}</span></div>
          <div>cell <span class="font-mono">{@cell_key}</span></div>
          <div>key <span class="font-mono">{@fingerprint}</span></div>
        </div>
      </div>

      <div class="mt-6 grid grid-cols-3 gap-6">
        <div class="col-span-2">
          <div class="flex gap-1 mb-2">
            <button
              :for={{label, cmd} <- [{"B", "bold"}, {"I", "italic"}, {"U", "underline"}]}
              type="button"
              data-format={cmd}
              class="editor-tool w-8 h-8 border border-slate-700 rounded hover:bg-slate-800 font-serif"
            >
              {label}
            </button>
            <button
              :for={
                {label, block} <- [{"H1", "h1"}, {"H2", "h2"}, {"\"", "quote"}, {"P", "paragraph"}]
              }
              type="button"
              data-block={block}
              class="editor-block w-10 h-8 border border-slate-700 rounded hover:bg-slate-800 text-xs"
            >
              {label}
            </button>
          </div>

          <div class="relative">
            <div
              id="editor"
              phx-hook="Lexical"
              phx-update="ignore"
              contenteditable="true"
              spellcheck="false"
              role="textbox"
              aria-multiline="true"
              data-state={@initial_state}
              data-head={@head}
              data-client-id={@client_id}
              class="min-h-[24rem] bg-slate-900/60 border border-slate-800 rounded p-6 prose prose-invert max-w-none focus:outline-none"
            >
            </div>

            <div id="cursors" phx-update="ignore" class="absolute inset-0 pointer-events-none"></div>
          </div>
        </div>

        <div class="text-xs space-y-4">
          <div class="border border-slate-800 rounded p-4">
            <div class="font-semibold text-slate-300">What the cell is doing</div>
            <p class="mt-2 text-slate-400">
              Yjs merges the edits — nobody loses a keystroke, even inside one word.
              What the cell provides is somewhere the update log cannot be lost, and
              a single writer for the one operation a CRDT does <em>not</em> make
              safe: collapsing that log into a snapshot.
            </p>
          </div>

          <div class="border border-slate-800 rounded p-4 space-y-1 font-mono">
            <div class="font-semibold text-slate-300 font-sans mb-2">This cell, right now</div>
            <div>log: {@stats.pending} updates, {@stats.pending_bytes} B</div>
            <div>snapshot: {@stats.snapshot_bytes} B through seq {@stats.through_seq}</div>
            <div>file: {@stats.file_bytes} B</div>
          </div>

          <button
            phx-click="compact"
            class="w-full border border-emerald-800 text-emerald-300 rounded px-3 py-2 hover:bg-emerald-950"
          >
            Compact the log
          </button>

          <p class="text-slate-500">
            Merge, write the snapshot, delete what was merged — one transaction on
            the cell's one connection. On shared storage this operation needs a lock
            or a designated compactor, or a concurrent writer's update disappears
            between the read and the delete.
          </p>

          <button
            phx-click="checkpoint"
            class="w-full border border-slate-700 rounded px-3 py-2 hover:bg-slate-800"
          >
            Checkpoint this cell
          </button>
        </div>
      </div>
    </div>
    """
  end
end
