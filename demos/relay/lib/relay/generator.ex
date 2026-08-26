defmodule Relay.Generator do
  @moduledoc """
  Produces tokens into one stream, and is the only writer of it.

  Stands in for whatever is generating — a model, a build log, a long export. What
  matters for the demo is that it is a *process*, that it is slow enough to watch,
  and that killing it mid-stream is the interesting case rather than an error.

  ## The generator flushes, and that is deliberate

  The flush could live in a separate ticker, and putting it here says something
  truer: the cell has one writer, and the flush is that writer's job. A second
  process flushing this stream would be a second writer of it, which the cell
  would serialise but which nothing in the *design* would have prevented.

  It also makes the RPO visible rather than described. Kill this process and
  everything appended since its last flush is in the cell file and not in the
  bucket. That is not a bug in the demo — it is
  [ADR-20](../../../../docs/decisions/ADR-20-choose-a-durability-level.md) and
  [DD-13](../../../../docs/design/DD-13-durable-streams.md)'s stated RPO, and the
  UI shows the gap rather than hiding it.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Relay.{Cells, Streams}

  @corpus ~w[
    the cell is one file and one writer so an offset is a name rather than a
    position in somebody's memory which is why a reader that reconnects after the
    process it was reading from has died can ask for what it has not seen yet and
    be given exactly that and nothing else
  ]

  @default_interval 60
  @default_flush_every 40

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  defp via(id), do: {:via, Registry, {Relay.GeneratorRegistry, id}}

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    prompt = Keyword.fetch!(opts, :prompt)
    cell = Cells.cell_key(id)

    AshCell.with_cell(cell, fn ->
      AshCell.repo().query!(
        "INSERT OR IGNORE INTO generation (id, prompt, started_at) VALUES (?, ?, ?)",
        [id, prompt, System.system_time(:millisecond)]
      )
    end)

    # Adopt the object store's watermark before writing a single token. On a cell
    # this node has just picked up, the local watermark came from whatever snapshot
    # was restored and may lag what the previous owner actually shipped — and a
    # flush that starts below the predecessor's last segment steps over it instead
    # of colliding with it, which is the fence undone.
    {:ok, _} = AshCell.Stream.adopt(store(), cell, Cells.stream())

    state = %{
      id: id,
      cell: cell,
      remaining: Keyword.get(opts, :tokens, 120),
      interval: Keyword.get(opts, :interval, @default_interval),
      flush_every: Keyword.get(opts, :flush_every, @default_flush_every),
      since_flush: 0
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: schedule(state)

  @impl true
  def handle_info(:tick, %{remaining: 0} = state) do
    flush(state)
    finish(state)
    Streams.broadcast(state.id, {:generation_finished, state.id})
    {:stop, :normal, state}
  end

  def handle_info(:tick, state) do
    token = Enum.random(@corpus) <> " "
    {:ok, offset} = AshCell.Stream.append(state.cell, Cells.stream(), token)

    Streams.broadcast(state.id, {:token, state.id, offset, token})

    state = %{state | remaining: state.remaining - 1, since_flush: state.since_flush + 1}

    state =
      if state.since_flush >= state.flush_every do
        flush(state)
        %{state | since_flush: 0}
      else
        state
      end

    schedule(state)
  end

  defp schedule(state) do
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  defp flush(state) do
    case AshCell.Stream.flush(store(), state.cell, Cells.stream(), retain: 0) do
      {:ok, %{start: start, end: last}} ->
        Streams.broadcast(state.id, {:flushed, state.id, start, last})

      {:ok, :nothing_to_flush} ->
        :ok

      # Fenced means another node owns this cell now. There is nothing useful to
      # do but stop: every further append is one that cannot be shipped.
      {:error, :fenced} ->
        Logger.error("relay: generation #{state.id} was fenced; stopping")
        exit(:fenced)

      {:error, reason} ->
        Logger.warning("relay: flush failed for #{state.id}: #{inspect(reason)}")
    end
  end

  defp finish(state) do
    AshCell.with_cell(state.cell, fn ->
      AshCell.repo().query!("UPDATE generation SET finished_at = ? WHERE id = ?", [
        System.system_time(:millisecond),
        state.id
      ])
    end)
  end

  defp store, do: Cells.store()
end
