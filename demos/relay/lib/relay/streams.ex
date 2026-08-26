defmodule Relay.Streams do
  @moduledoc """
  The demo's whole API, and it is thin on purpose.

  Everything durable here is `AshCell.Stream`. What this module adds is the parts
  a *product* needs and the library deliberately does not have: a live transport,
  a process that produces the tokens, and the metadata row about the generation.

  ## The tiers, and why the live one is not the object store

  A subscriber gets tokens over `Phoenix.PubSub` as they are appended. That is the
  only path in the live case — the object store is never in the append path and
  never in the fan-out path, because a PUT is 50–200 ms and a token is not.

  A *resuming* subscriber is the interesting case, and it is the one `resume/2`
  serves: it asks for everything after the offset it last saw, which the library
  stitches from segments, then the cell, and only then does it subscribe. The
  ordering matters — subscribe first and you get a duplicate; subscribe last
  without re-reading and you get a gap. `resume/2` returns the offset it read up
  to, and the caller subscribes and then drops any live message at or below it.
  """

  alias Relay.{Cells, Generator}

  @doc "Starts generating into a new stream. Returns the generation id."
  def start(prompt, opts \\ []) do
    id = Keyword.get_lazy(opts, :id, &new_id/0)

    case DynamicSupervisor.start_child(
           Relay.GeneratorSupervisor,
           {Generator, Keyword.merge(opts, id: id, prompt: prompt)}
         ) do
      {:ok, _pid} -> {:ok, id}
      {:error, {:already_started, _pid}} -> {:ok, id}
      other -> other
    end
  end

  @doc """
  Kills the process producing a stream, mid-token, without ceremony.

  `Process.exit(pid, :kill)` rather than a graceful stop, because a graceful stop
  would flush on the way out and prove nothing. What must survive here is the
  ungraceful case.
  """
  def kill(id) do
    case Registry.lookup(Relay.GeneratorRegistry, id) do
      [{pid, _}] -> Process.exit(pid, :kill)
      [] -> :ok
    end
  end

  def generating?(id), do: Registry.lookup(Relay.GeneratorRegistry, id) != []

  @doc """
  Everything after `from`, and the offset that read reached.

  The caller subscribes *after* this returns and discards any live message whose
  offset is not greater than `:through` — which is the only way to close the
  window between the two without a gap or a duplicate.
  """
  def resume(id, from) do
    case AshCell.Stream.read(store!(), Cells.cell_key(id), Cells.stream(), from, limit: 100_000) do
      {:ok, entries} ->
        through = if entries == [], do: from, else: List.last(entries).offset
        {:ok, %{entries: entries, through: through}}

      other ->
        other
    end
  end

  @doc "Pushes whatever is unflushed into a segment. Ordinarily the generator's job."
  def flush(id) do
    AshCell.Stream.flush(store!(), Cells.cell_key(id), Cells.stream(), retain: 0)
  end

  @doc """
  Closes the cell, leaving its file on disk and its segments in the bucket.

  Stands in for the node that was serving this stream going away. A resume after
  this has to reopen the cell, which is the cheap half of the story; `evict!/1`
  with `delete: true` is the expensive half, where the file is gone and the
  segments are all there is.
  """
  def evict(id, opts \\ []) do
    cell = Cells.cell_key(id)

    if Keyword.get(opts, :delete, false) do
      AshCell.Manager.delete(cell)
    else
      AshCell.Manager.close(cell, await_repo?: true)
    end
  end

  @doc """
  Where this stream's entries actually are, for the UI to show rather than claim.
  """
  def tiers(id) do
    cell = Cells.cell_key(id)
    store = store!()

    with {:ok, watermark} <- AshCell.Stream.latest_offset(store, cell, Cells.stream()),
         {:ok, keys} <-
           AshCell.ObjectStore.list(store, AshCell.Stream.segment_prefix(cell, Cells.stream())) do
      {:ok, head} = AshCell.Stream.head(cell, Cells.stream())

      {:ok,
       %{
         head: head,
         flushed_through: watermark,
         segments: length(keys),
         in_cell: max(head - watermark, 0)
       }}
    end
  end

  # ── the live half ─────────────────────────────────────────────────────────

  def subscribe(id), do: Phoenix.PubSub.subscribe(Relay.PubSub, topic(id))
  def unsubscribe(id), do: Phoenix.PubSub.unsubscribe(Relay.PubSub, topic(id))

  @doc false
  def broadcast(id, message), do: Phoenix.PubSub.broadcast(Relay.PubSub, topic(id), message)

  defp topic(id), do: "generation:" <> id

  defp new_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp store! do
    Cells.store() ||
      raise """
      relay needs an object store and none is configured.

      Without a bucket there are no segments, so a resume can only ever be served
      from the cell — which is the half of this demo that was already easy. Start
      MinIO (see the README) and set the RELAY_S3_* variables.
      """
  end
end
