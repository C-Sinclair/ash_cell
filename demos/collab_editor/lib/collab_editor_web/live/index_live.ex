defmodule CollabEditorWeb.IndexLive do
  @moduledoc """
  The document list, which is a fan-out over cells rather than a query.

  Each row is one encrypted SQLite file: its own key, its own op log, its own
  snapshot lineage. The columns are the evidence — a path you can `ls`, a size you
  can watch grow as people type, and a key fingerprint that is different for every
  document.
  """
  use CollabEditorWeb, :live_view

  alias CollabEditor.{CellKey, Editing}
  alias CollabEditor.Cells.Vault

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, documents: rows(), resident: AshCell.resident_cells())}
  end

  @impl true
  def handle_event("create", %{"title" => title}, socket) do
    title = if String.trim(title) == "", do: "Untitled", else: title
    {:ok, document} = Editing.create_document(title)
    {:noreply, push_navigate(socket, to: ~p"/docs/#{document.id}")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    Editing.delete_document(id)
    {:noreply, assign(socket, documents: rows(), resident: AshCell.resident_cells())}
  end

  def handle_event("close", %{"id" => id}, socket) do
    AshCell.close(CellKey.resolve(id))
    {:noreply, assign(socket, resident: AshCell.resident_cells())}
  end

  defp rows do
    for document <- Editing.list_documents() do
      cell_key = CellKey.resolve(document.id)
      stats = Editing.stats(document.id)

      %{
        id: document.id,
        title: document.title,
        created_at: document.created_at,
        cell_key: cell_key,
        path: AshCell.path_for(cell_key),
        stats: stats,
        fingerprint: Vault.fingerprint(cell_key)
      }
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-8 text-slate-100">
      <h1 class="text-2xl font-semibold">Documents</h1>
      <p class="mt-2 text-slate-400 max-w-2xl">
        One document is one cell: one encrypted SQLite file holding that document's
        whole Yjs update log, one owner, one snapshot lineage. This list is a fan-out
        that opens every cell to read a single row — there is no shared table to
        query, which is the cost side of cutting cells this fine.
      </p>

      <form phx-submit="create" class="mt-6 flex gap-2">
        <input
          type="text"
          name="title"
          placeholder="New document title"
          class="flex-1 bg-slate-800 border border-slate-700 rounded px-3 py-2"
        />
        <button class="bg-emerald-600 hover:bg-emerald-500 rounded px-4 py-2 font-medium">
          Create cell
        </button>
      </form>

      <div class="mt-8 space-y-3">
        <div :for={row <- @documents} class="border border-slate-800 rounded p-4 bg-slate-900/60">
          <div class="flex items-center justify-between gap-4">
            <div>
              <.link navigate={~p"/docs/#{row.id}"} class="text-lg font-medium hover:underline">
                {row.title}
              </.link>
              <div class="text-xs text-slate-500 font-mono mt-1">{row.path}</div>
            </div>
            <div class="text-right text-xs text-slate-400 space-y-1">
              <%= if row.stats == :unavailable do %>
                <div class="text-amber-400">cell unreadable</div>
              <% else %>
                <div>{row.stats.file_bytes} bytes on disk</div>
                <div>
                  {row.stats.pending} updates in the log, snapshot through seq {row.stats.through_seq}
                </div>
              <% end %>
              <div>key <span class="font-mono">{row.fingerprint}</span></div>
              <div :if={row.cell_key in @resident} class="text-emerald-400">resident</div>
            </div>
            <div class="flex flex-col gap-2">
              <button
                phx-click="close"
                phx-value-id={row.id}
                class="text-xs border border-slate-700 rounded px-2 py-1 hover:bg-slate-800"
              >
                Close cell
              </button>
              <button
                phx-click="delete"
                phx-value-id={row.id}
                data-confirm="Delete this document's file entirely?"
                class="text-xs border border-red-900 text-red-300 rounded px-2 py-1 hover:bg-red-950"
              >
                rm
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
