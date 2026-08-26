defmodule AshCell.Stream do
  @moduledoc """
  An append-only stream inside a cell whose **offsets survive the writer**.

  A reader holding offset N gets exactly the suffix after N — after the process
  generating it has died, after the cell has moved to another node, and after the
  entries it wants have been truncated out of the cell file. That is the whole
  feature: an offset is a durable name rather than a session-local counter.

  See [DD-13](../../docs/design/DD-13-durable-streams.md).

  ## The three tiers, and the stitch between them

  An entry is in one of three places, and a resuming reader may need all three:

    * **live** — being appended now, fanned out by `Phoenix.PubSub`. Not this
      module's job, and deliberately so: the object store is never in the live
      path and never in the append path.
    * **the cell** — appended, not yet flushed, or flushed and retained. Rows in
      `ash_cell_stream_entries`.
    * **the object store** — flushed into an immutable, offset-keyed segment and
      truncated locally.

  `read/5` walks them in that order, backwards: cell first, and when the cell's
  lowest surviving offset is above the cursor, the gap below it is fetched from
  segments. This is correct for one reason and it is worth stating plainly,
  because it is the only thing holding the design up:

  > **A flush strictly precedes the truncation of what it flushed.** So every
  > offset missing from the cell is already in a segment, and the union of the two
  > always covers the stream with no gap. A truncation that ran optimistically
  > ahead of its PUT would break resume and nothing else would notice.

  ## Fencing: the segment key is the offset, and only the start

  Segments are written with `If-None-Match` under

      cells/<enc(cell_key)>/streams/<enc(stream)>/segments/<pad(start)>.seg

  keyed by the **start offset alone**. That is the same mechanism as
  `AshCell.Replicator`'s txid keys and it fails the same way if you get it wrong.

  Keying by `start-end` reads better and fences nothing: two owners batch
  differently, so a displaced writer flushing `101-150` and its successor flushing
  `101-200` address different keys, both conditional writes succeed, and the loser
  is acknowledged before being silently superseded. That is
  [ADR-08](../../docs/decisions/ADR-08-fence-by-shared-txid.md)'s generation bug
  wearing a different hat, and `test/stream_test.exs` asserts both halves — that
  `start` collides, and that `start-end` would not have.

  Keyed by `start`, both owners compute the same next key from a watermark they
  both read from the store, exactly one wins, and the loser finds out before it
  has told anybody the data is durable.

  ## A crash between the PUT and the local commit

  The flush spans a boundary that cannot be transactional: an object store PUT and
  a SQLite commit. So the intent is written to the cell *first* — `pending_start`,
  `pending_end`, `pending_digest` — and a flush that finds a stale intent can tell
  the two cases apart by digest rather than by guessing:

    * segment absent → the PUT never landed; discard the intent and re-flush.
    * segment present, digest matches → it was ours; adopt it and truncate.
    * segment present, digest differs → somebody else owns this stream now. Fence.

  ## What this is not

  Not Kafka. One stream, one writer, N independent readers each holding their own
  offset; no partitions, no consumer groups, no cross-stream ordering. Not
  exactly-once: a reader that crashes before recording its offset re-reads. And
  **not RPO=0** — a returned `append/4` is in the cell file, not in the object
  store, and reaches it at the next flush. See
  [ADR-20](../../docs/decisions/ADR-20-choose-a-durability-level.md).
  """

  require Logger

  @magic "ACS1"
  @default_batch 1_000
  @default_limit 1_000

  # ── schema ────────────────────────────────────────────────────────────────

  @doc """
  Creates the two tables this needs, in the cell `repo_pid` is connected to.

  Call it from the application's migrator; the library does not own the fleet's
  migration list.

      migration 3, &AshCell.Stream.migrate/1
  """
  def migrate(repo_pid) do
    Ecto.Adapters.SQL.query!(repo_pid, """
    CREATE TABLE IF NOT EXISTS ash_cell_stream_entries (
      stream TEXT NOT NULL,
      seq INTEGER NOT NULL,
      payload BLOB NOT NULL,
      at INTEGER NOT NULL,
      PRIMARY KEY (stream, seq)
    )
    """)

    Ecto.Adapters.SQL.query!(repo_pid, """
    CREATE TABLE IF NOT EXISTS ash_cell_stream_meta (
      stream TEXT PRIMARY KEY,
      flushed_through INTEGER NOT NULL DEFAULT 0,
      pending_start INTEGER,
      pending_end INTEGER,
      pending_digest TEXT
    )
    """)

    :ok
  end

  # ── object-store layout ───────────────────────────────────────────────────

  @doc "Where a stream's segments live. One namespace per stream, per cell."
  def segment_prefix(cell_key, stream) do
    "cells/#{AshCell.CellKey.encode(cell_key)}/streams/#{AshCell.CellKey.encode(stream)}/segments/"
  end

  @doc """
  The key for the segment starting at `start`.

  The start offset alone. See the module doc for why encoding the end here would
  remove the fence.
  """
  def segment_key(cell_key, stream, start) do
    "#{segment_prefix(cell_key, stream)}#{pad(start)}.seg"
  end

  # ── append ────────────────────────────────────────────────────────────────

  @doc """
  Appends one payload, or a list of them, returning the offset of the last.

  Offsets are dense and monotonic within a stream, allocated as `MAX(seq) + 1`
  inside one `BEGIN IMMEDIATE` transaction. There is one writer, so the read is
  free and no sequence is needed
  ([ADR-04](../../docs/decisions/ADR-04-transactions-behind-an-opt-in-flag.md)).
  """
  def append(cell_key, stream, payload, opts \\ [])

  def append(cell_key, stream, payload, opts) when is_binary(payload) do
    append(cell_key, stream, [payload], opts)
  end

  def append(cell_key, stream, payloads, _opts) when is_list(payloads) do
    at = System.system_time(:millisecond)

    in_cell(cell_key, fn repo ->
      txn(fn ->
        ensure_meta(repo, stream)
        # Not `MAX(seq)` alone: a flush truncates flushed entries out of the table,
        # so on an empty tail that is 0 and the next append would reissue offset 1
        # over a stream that is already ten thousand entries long. The watermark is
        # what remembers the ones that have gone.
        base = max(max_seq(repo, stream), flushed_through(repo, stream))

        payloads
        |> Enum.with_index(base + 1)
        |> Enum.each(fn {payload, seq} ->
          query!(
            repo,
            "INSERT INTO ash_cell_stream_entries (stream, seq, payload, at) VALUES (?, ?, ?, ?)",
            [stream, seq, payload, at]
          )
        end)

        {:ok, base + length(payloads)}
      end)
    end)
  end

  @doc "The highest offset this cell holds for `stream`, flushed or not."
  def head(cell_key, stream) do
    in_cell(cell_key, fn repo ->
      {:ok, max(max_seq(repo, stream), flushed_through(repo, stream))}
    end)
  end

  # ── read ──────────────────────────────────────────────────────────────────

  @doc """
  Entries with offset strictly greater than `from`, in order.

  `from: 0` is the beginning of the stream. Options:

    * `:limit` — how many entries at most (default #{@default_limit}).
    * `:local?` — when `false`, never touches the cell and reads only from
      segments. For a reader on a node that does not own the cell and must not
      cause it to be activated.

  Returns `{:ok, [%{offset: integer, payload: binary, at: integer}]}`.
  """
  def read(store, cell_key, stream, from, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    if Keyword.get(opts, :local?, true) do
      stitched(store, cell_key, stream, from, limit)
    else
      from_segments(store, cell_key, stream, from, limit)
    end
  end

  # Cell first, then fill the gap below it from segments. The cell's lowest
  # surviving offset being above the cursor is exactly the signal that a flush has
  # truncated what we want, and because the flush preceded that truncation the
  # segment holding it is already there.
  defp stitched(store, cell_key, stream, from, limit) do
    with {:ok, local} <- local_entries(cell_key, stream, from, limit) do
      case local do
        [%{offset: offset} | _] when offset == from + 1 ->
          {:ok, local}

        _ ->
          gap_end = if local == [], do: nil, else: hd(local).offset - 1

          with {:ok, cold} <- from_segments(store, cell_key, stream, from, limit, gap_end) do
            {:ok, Enum.take(cold ++ local, limit)}
          end
      end
    end
  end

  defp from_segments(store, cell_key, stream, from, limit, until \\ nil) do
    with {:ok, starts} <- segment_starts(store, cell_key, stream) do
      starts
      |> Enum.filter(&(is_nil(until) or &1 <= until))
      |> Enum.reduce_while({:ok, []}, fn start, {:ok, acc} ->
        if length(acc) >= limit do
          {:halt, {:ok, acc}}
        else
          case fetch_segment(store, cell_key, stream, start) do
            {:ok, %{end: last}} when last <= from ->
              {:cont, {:ok, acc}}

            {:ok, segment} ->
              wanted =
                segment.entries
                |> Enum.filter(&(&1.offset > from))
                |> Enum.filter(&(is_nil(until) or &1.offset <= until))

              {:cont, {:ok, acc ++ wanted}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end
      end)
      |> case do
        {:ok, entries} ->
          # `uniq_by` after the sort, not decoration: one offset must appear once.
          #
          # This is not defensive coding, it is a corrected assumption. The stitch
          # was written believing the segment set is a disjoint cover, so the union
          # needed no de-duplication. Measured false: under a concurrent PUT the
          # store's own listing returned the same key twice, and a single offset
          # came back twice from one segment fetched twice — a duplicate in a
          # resumed stream, which for a token stream is a repeated word and for an
          # event stream is a repeated effect.
          #
          # Overlapping segments are separately possible and this covers them too.
          # A displaced writer and its successor can hold different watermarks, so
          # one may write `10` covering 10..13 while the other writes `12` covering
          # 12..15: different keys, so neither conditional write is refused, and the
          # start-only key does not fence that case. Taking the entry from the
          # lowest-keyed segment is at least deterministic.
          {:ok,
           entries |> Enum.sort_by(& &1.offset) |> Enum.uniq_by(& &1.offset) |> Enum.take(limit)}

        other ->
          other
      end
    end
  end

  defp local_entries(cell_key, stream, from, limit) do
    in_cell(cell_key, fn repo ->
      %{rows: rows} =
        query!(
          repo,
          """
          SELECT seq, payload, at FROM ash_cell_stream_entries
          WHERE stream = ? AND seq > ? ORDER BY seq LIMIT ?
          """,
          [stream, from, limit]
        )

      {:ok, Enum.map(rows, fn [seq, payload, at] -> %{offset: seq, payload: payload, at: at} end)}
    end)
  end

  # ── flush ─────────────────────────────────────────────────────────────────

  @doc """
  Batches unflushed entries into a segment, then truncates them locally.

  Options:

    * `:batch` — the most entries in one segment (default #{@default_batch}).
    * `:retain` — entries to keep in the cell behind the flush watermark
      (default 0). A read-locality knob only: correctness must not depend on it,
      which is why the default is the one that tests the stitch hardest.

  Returns `{:ok, :nothing_to_flush}`, `{:ok, %{start:, end:, bytes:}}`, or
  `{:error, :fenced}` — the last meaning another owner has taken this stream, at
  which point the cell is quarantined
  ([ADR-10](../../docs/decisions/ADR-10-fail-closed-on-a-refused-shipment.md)).
  """
  def flush(store, cell_key, stream, opts \\ []) do
    batch = Keyword.get(opts, :batch, @default_batch)
    retain = Keyword.get(opts, :retain, 0)

    with :ok <- resolve_pending(store, cell_key, stream, retain) do
      do_flush(store, cell_key, stream, batch, retain)
    end
  end

  defp do_flush(store, cell_key, stream, batch, retain) do
    {:ok, watermark} = in_cell(cell_key, fn repo -> {:ok, flushed_through(repo, stream)} end)

    case local_entries(cell_key, stream, watermark, batch) do
      {:ok, []} ->
        {:ok, :nothing_to_flush}

      {:ok, entries} ->
        start = hd(entries).offset
        last = List.last(entries).offset
        body = encode_segment(stream, start, last, entries)
        digest = digest(body)

        :ok = record_intent(cell_key, stream, start, last, digest)

        case AshCell.ObjectStore.put(store, segment_key(cell_key, stream, start), body,
               if_none_match: true
             ) do
          {:ok, _etag} ->
            :ok = commit_flush(cell_key, stream, last, retain)
            {:ok, %{start: start, end: last, bytes: byte_size(body)}}

          {:error, :precondition_failed} ->
            settle_collision(store, cell_key, stream, start, last, digest, retain)

          {:error, reason} ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  # A colliding key is either our own earlier write finishing late, or a
  # successor's. The digest is what separates them, and being wrong in the
  # permissive direction is the one failure this whole namespace exists to stop.
  defp settle_collision(store, cell_key, stream, start, last, digest, retain) do
    case AshCell.ObjectStore.get(store, segment_key(cell_key, stream, start)) do
      {:ok, body, _etag} ->
        if digest(body) == digest do
          :ok = commit_flush(cell_key, stream, last, retain)
          {:ok, %{start: start, end: last, bytes: byte_size(body)}}
        else
          fence(cell_key, stream, start)
        end

      {:error, :not_found} ->
        # The key was taken and is now gone. Not a case this design produces —
        # segments are immutable and never deleted — so treat it as hostile.
        fence(cell_key, stream, start)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fence(cell_key, stream, start) do
    Logger.error("""
    ash_cell: stream #{inspect(stream)} in cell #{inspect(cell_key)} was fenced at \
    offset #{start} — the segment key is held by another owner. This node no longer \
    owns this cell and has stopped serving it.
    """)

    AshCell.Manager.fence(cell_key)
    {:error, :fenced}
  end

  # Stage 1 of the flush: say what we are about to do, in the cell, before the PUT.
  defp record_intent(cell_key, stream, start, last, digest) do
    in_cell(cell_key, fn repo ->
      txn(fn ->
        query!(
          repo,
          """
          UPDATE ash_cell_stream_meta
          SET pending_start = ?, pending_end = ?, pending_digest = ?
          WHERE stream = ?
          """,
          [start, last, digest, stream]
        )

        :ok
      end)
    end)
  end

  # Stage 3: the watermark advances and the flushed entries go, in one transaction.
  defp commit_flush(cell_key, stream, last, retain) do
    in_cell(cell_key, fn repo ->
      txn(fn ->
        query!(
          repo,
          """
          UPDATE ash_cell_stream_meta
          SET flushed_through = ?, pending_start = NULL, pending_end = NULL,
              pending_digest = NULL
          WHERE stream = ?
          """,
          [last, stream]
        )

        query!(
          repo,
          "DELETE FROM ash_cell_stream_entries WHERE stream = ? AND seq <= ?",
          [stream, last - retain]
        )

        :ok
      end)
    end)
  end

  # A stale intent means we died between the PUT and the commit. Which of the two
  # happened is decidable, and guessing is not acceptable in either direction.
  defp resolve_pending(store, cell_key, stream, retain) do
    {:ok, pending} =
      in_cell(cell_key, fn repo ->
        ensure_meta(repo, stream)

        %{rows: [[start, last, digest]]} =
          query!(
            repo,
            "SELECT pending_start, pending_end, pending_digest FROM ash_cell_stream_meta WHERE stream = ?",
            [stream]
          )

        {:ok, if(is_nil(start), do: nil, else: %{start: start, end: last, digest: digest})}
      end)

    case pending do
      nil ->
        :ok

      %{start: start, end: last, digest: digest} ->
        case AshCell.ObjectStore.get(store, segment_key(cell_key, stream, start)) do
          {:ok, body, _etag} ->
            if digest(body) == digest do
              commit_flush(cell_key, stream, last, retain)
            else
              fence(cell_key, stream, start)
            end

          {:error, :not_found} ->
            clear_intent(cell_key, stream)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp clear_intent(cell_key, stream) do
    in_cell(cell_key, fn repo ->
      query!(
        repo,
        "UPDATE ash_cell_stream_meta SET pending_start = NULL, pending_end = NULL, pending_digest = NULL WHERE stream = ?",
        [stream]
      )

      :ok
    end)
  end

  @doc """
  The highest offset in the object store for this stream, or `0` if never flushed.

  Read **once**, when a node adopts the cell, and advanced locally thereafter —
  the same rule, for the same reason, as `AshCell.Replicator.latest_txid/2`. A
  writer that re-read this before each flush would read its successor's watermark
  and write safely past it, which is the fence undone.

  A store that cannot be listed is an error, never `{:ok, 0}`.
  """
  def latest_offset(store, cell_key, stream) do
    with {:ok, starts} <- segment_starts(store, cell_key, stream) do
      case List.last(starts) do
        nil ->
          {:ok, 0}

        start ->
          with {:ok, segment} <- fetch_segment(store, cell_key, stream, start) do
            {:ok, segment.end}
          end
      end
    end
  end

  @doc """
  Adopts a stream's watermark from the object store into this cell.

  Called after restoring a cell on a new node: the local `flushed_through` came
  from whatever snapshot was restored and may lag what the previous owner actually
  shipped. Adopting the store's value is what makes the next segment key collide
  with the predecessor's rather than step over it.
  """
  def adopt(store, cell_key, stream) do
    with {:ok, offset} <- latest_offset(store, cell_key, stream) do
      in_cell(cell_key, fn repo ->
        txn(fn ->
          ensure_meta(repo, stream)

          query!(
            repo,
            "UPDATE ash_cell_stream_meta SET flushed_through = MAX(flushed_through, ?) WHERE stream = ?",
            [offset, stream]
          )

          {:ok, offset}
        end)
      end)
    end
  end

  defp segment_starts(store, cell_key, stream) do
    with {:ok, keys} <- AshCell.ObjectStore.list(store, segment_prefix(cell_key, stream)) do
      # `uniq` because a listing is not trusted to be duplicate-free. Observed:
      # MinIO returned one key twice while another was being written, and the
      # segment was then fetched twice and its entries emitted twice.
      {:ok,
       keys
       |> Enum.map(&(&1 |> Path.basename(".seg") |> String.to_integer()))
       |> Enum.uniq()
       |> Enum.sort()}
    end
  end

  defp fetch_segment(store, cell_key, stream, start) do
    with {:ok, body, _etag} <-
           AshCell.ObjectStore.get(store, segment_key(cell_key, stream, start)) do
      decode_segment(body)
    end
  end

  # ── segment format ────────────────────────────────────────────────────────
  #
  # "ACS1", a 4-byte header length, a JSON header, then framed entries. The header
  # carries the end offset, so a segment's extent is discoverable without the key
  # encoding it — which is what lets the key stay start-only and still fence.

  @doc false
  def encode_segment(stream, start, last, entries) do
    header =
      Jason.encode!(%{v: 1, stream: stream, start: start, end: last, count: length(entries)})

    frames =
      Enum.map(entries, fn %{offset: offset, payload: payload, at: at} ->
        [<<offset::64, at::64, byte_size(payload)::32>>, payload]
      end)

    IO.iodata_to_binary([@magic, <<byte_size(header)::32>>, header, frames])
  end

  @doc false
  def decode_segment(<<@magic, header_len::32, rest::binary>>) do
    <<header::binary-size(header_len), frames::binary>> = rest
    header = Jason.decode!(header)

    {:ok,
     %{
       stream: header["stream"],
       start: header["start"],
       end: header["end"],
       entries: decode_frames(frames, [])
     }}
  end

  def decode_segment(_other), do: {:error, :malformed_segment}

  defp decode_frames(<<>>, acc), do: Enum.reverse(acc)

  defp decode_frames(
         <<offset::64, at::64, len::32, payload::binary-size(len), rest::binary>>,
         acc
       ) do
    decode_frames(rest, [%{offset: offset, payload: payload, at: at} | acc])
  end

  # ── cell plumbing ─────────────────────────────────────────────────────────

  # The repo *module*, not the cell's connection pid. Both reach the same database
  # once `with_cell/2` has bound it, but only the module routes through Ecto's
  # checkout — and a transaction has to hold its connection to be one.
  defp in_cell(cell_key, fun) do
    AshCell.with_cell(cell_key, fn ->
      {:ok, _pid} = AshCell.Manager.ensure_started(cell_key)
      fun.(AshCell.repo())
    end)
  end

  # `mode: :immediate`, not a deferred `BEGIN`. A deferred read-then-write has to
  # upgrade its lock, and SQLite fails that upgrade immediately regardless of
  # `busy_timeout` — and every write here reads before it writes.
  #
  # This was hand-rolled as raw `BEGIN IMMEDIATE`/`COMMIT` against the connection
  # pid first, which is what `AshCell.Migrator` does, and it is wrong anywhere the
  # migrator is not: raw statements do not hold the connection, so an appender and
  # a flusher in two processes interleaved their transactions on the single pooled
  # connection and SQLite refused with "cannot start a transaction within a
  # transaction". Going through the repo makes the second writer *wait* for the
  # connection instead, which is the serialisation the cell is supposed to provide.
  defp txn(fun) do
    {:ok, result} = AshCell.repo().transaction(fun, mode: :immediate)
    result
  end

  defp ensure_meta(repo, stream) do
    query!(repo, "INSERT OR IGNORE INTO ash_cell_stream_meta (stream) VALUES (?)", [stream])
  end

  defp max_seq(repo, stream) do
    %{rows: [[value]]} =
      query!(repo, "SELECT COALESCE(MAX(seq), 0) FROM ash_cell_stream_entries WHERE stream = ?", [
        stream
      ])

    value
  end

  defp flushed_through(repo, stream) do
    %{rows: rows} =
      query!(repo, "SELECT flushed_through FROM ash_cell_stream_meta WHERE stream = ?", [stream])

    case rows do
      [[value]] -> value
      [] -> 0
    end
  end

  # `repo.query!/2`, not `Ecto.Adapters.SQL.query!/3`. The latter resolves the repo
  # module through Ecto's *named* registry, and a cell's repo is reached only via
  # `put_dynamic_repo/1` and has no named process — so it raises "repo not started"
  # from inside a transaction that had just successfully opened on that same cell.
  defp query!(repo, sql, params), do: repo.query!(sql, params)

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp pad(offset), do: offset |> Integer.to_string() |> String.pad_leading(18, "0")
end
