defmodule RelayWeb.StreamLive do
  @moduledoc """
  Watching a stream, and resuming one.

  The mount is the demo. A fresh mount and a reconnect after twenty minutes take
  the *same* path: ask for everything after the offset this client last saw, then
  subscribe, then discard anything live that the read already covered. There is no
  separate "catch up" mode, because an offset that survives the writer makes the
  two cases the same case.

  Note what is *not* here: no `AshCell.LiveView`, no `bind_held/1`. This view never
  touches an Ash resource — `AshCell.Stream` binds the cell for itself, once per
  statement, from the process about to issue it. A LiveView holding a binding
  across callbacks would be solving a problem this page does not have.
  """
  use RelayWeb, :live_view

  alias Relay.Streams

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(
        id: params["id"],
        from: parse_offset(params["from"]),
        tokens: [],
        through: 0,
        tiers: nil,
        status: :idle,
        prompt: "explain the cell model",
        error: nil
      )

    if connected?(socket) and socket.assigns.id do
      {:ok, attach(socket, socket.assigns.id, socket.assigns.from)}
    else
      {:ok, socket}
    end
  end

  # Read first, subscribe second, then drop what the read already covered. The
  # other orderings are a duplicate and a gap respectively.
  defp attach(socket, id, from) do
    case Streams.resume(id, from) do
      {:ok, %{entries: entries, through: through}} ->
        Streams.subscribe(id)

        socket
        |> assign(
          tokens: Enum.map(entries, &{&1.offset, &1.payload}),
          through: through,
          status: if(Streams.generating?(id), do: :generating, else: :idle),
          error: nil
        )
        |> load_tiers()

      {:error, reason} ->
        assign(socket, error: inspect(reason))
    end
  end

  @impl true
  def handle_event("start", %{"prompt" => prompt}, socket) do
    {:ok, id} = Streams.start(prompt)
    {:noreply, push_patch(socket, to: ~p"/g/#{id}")}
  end

  def handle_event("kill", _params, socket) do
    Streams.kill(socket.assigns.id)
    {:noreply, socket |> assign(status: :killed) |> load_tiers()}
  end

  def handle_event("flush", _params, socket) do
    Streams.flush(socket.assigns.id)
    {:noreply, load_tiers(socket)}
  end

  def handle_event("evict", _params, socket) do
    Streams.evict(socket.assigns.id)
    {:noreply, load_tiers(socket)}
  end

  # Resume from where this client is, having thrown away everything it holds. The
  # honest version of a reconnect: same offset, no cached tokens, no live socket.
  def handle_event("resume", _params, socket) do
    id = socket.assigns.id
    Streams.unsubscribe(id)
    {:noreply, socket |> assign(tokens: []) |> attach(id, 0)}
  end

  def handle_event("resume_here", _params, socket) do
    id = socket.assigns.id
    from = socket.assigns.through
    Streams.unsubscribe(id)
    {:noreply, socket |> assign(tokens: []) |> attach(id, from)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if connected?(socket) and socket.assigns.id != id do
      if socket.assigns.id, do: Streams.unsubscribe(socket.assigns.id)
      {:noreply, socket |> assign(id: id, tokens: []) |> attach(id, 0)}
    else
      {:noreply, assign(socket, id: id)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:token, _id, offset, token}, socket) do
    # The guard that makes read-then-subscribe safe. Without it, every token the
    # resume already returned arrives a second time.
    if offset > socket.assigns.through do
      {:noreply,
       assign(socket,
         tokens: socket.assigns.tokens ++ [{offset, token}],
         through: offset,
         status: :generating
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:flushed, _id, _start, _last}, socket), do: {:noreply, load_tiers(socket)}

  def handle_info({:generation_finished, _id}, socket) do
    {:noreply, socket |> assign(status: :finished) |> load_tiers()}
  end

  defp load_tiers(%{assigns: %{id: nil}} = socket), do: socket

  defp load_tiers(socket) do
    case Streams.tiers(socket.assigns.id) do
      {:ok, tiers} -> assign(socket, tiers: tiers)
      {:error, _} -> socket
    end
  end

  defp parse_offset(nil), do: 0

  defp parse_offset(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 -> offset
      _ -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-8 space-y-6">
      <header>
        <h1 class="text-2xl font-semibold">relay</h1>
        <p class="text-sm text-zinc-500">
          One cell per stream. An offset is a durable name, so a reader that
          reconnects asks for what it has not seen and gets exactly that.
        </p>
      </header>

      <form phx-submit="start" class="flex gap-2">
        <input
          type="text"
          name="prompt"
          value={@prompt}
          class="flex-1 rounded border px-3 py-2 text-sm"
        />
        <button class="rounded bg-zinc-900 px-4 py-2 text-sm text-white">generate</button>
      </form>

      <div :if={@error} class="rounded bg-red-50 p-4 text-sm text-red-700">{@error}</div>

      <div :if={@id} class="space-y-4">
        <div class="flex flex-wrap items-center gap-2 text-sm">
          <span class="rounded bg-zinc-100 px-2 py-1 font-mono">{@id}</span>
          <span class="rounded bg-zinc-100 px-2 py-1">offset {@through}</span>
          <span class="rounded bg-zinc-100 px-2 py-1">{@status}</span>
        </div>

        <div class="rounded border bg-white p-4 font-mono text-sm leading-relaxed min-h-32">
          {Enum.map_join(@tokens, "", fn {_offset, token} -> token end)}
        </div>

        <div :if={@tiers} class="grid grid-cols-4 gap-2 text-center text-sm">
          <div class="rounded bg-zinc-100 p-3">
            <div class="text-lg font-semibold">{@tiers.head}</div>
            <div class="text-xs text-zinc-500">appended</div>
          </div>
          <div class="rounded bg-zinc-100 p-3">
            <div class="text-lg font-semibold">{@tiers.flushed_through}</div>
            <div class="text-xs text-zinc-500">in the bucket</div>
          </div>
          <div class="rounded bg-zinc-100 p-3">
            <div class="text-lg font-semibold">{@tiers.in_cell}</div>
            <div class="text-xs text-zinc-500">
              only in the cell
            </div>
          </div>
          <div class="rounded bg-zinc-100 p-3">
            <div class="text-lg font-semibold">{@tiers.segments}</div>
            <div class="text-xs text-zinc-500">segments</div>
          </div>
        </div>

        <p class="text-xs text-zinc-500">
          "only in the cell" is the RPO, in entries. Kill the generator and that
          many tokens are on local disk and not in the bucket.
        </p>

        <div class="flex flex-wrap gap-2 text-sm">
          <button phx-click="kill" class="rounded border px-3 py-2">kill the generator</button>
          <button phx-click="flush" class="rounded border px-3 py-2">flush now</button>
          <button phx-click="evict" class="rounded border px-3 py-2">close the cell</button>
          <button phx-click="resume_here" class="rounded border px-3 py-2">
            reconnect at {@through}
          </button>
          <button phx-click="resume" class="rounded border px-3 py-2">replay from 0</button>
        </div>
      </div>
    </div>
    """
  end
end
