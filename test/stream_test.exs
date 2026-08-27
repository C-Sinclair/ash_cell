defmodule AshCell.StreamTest do
  @moduledoc """
  Whether an offset survives the writer.

  The load-bearing test in here is `resume is exact while a flush runs`. Everything
  else could pass and that one fail, and the failure mode is the one that matters:
  a reader that reconnects and silently skips the entries a flush truncated out of
  the cell between its two reads.

  Two others guard mistakes already made rather than imagined. `offsets do not
  restart after a truncation` guards a bug that was written and caught here —
  `MAX(seq)` on a truncated table is 0, so the next append reissued offset 1 over a
  stream thousands of entries long. And `a start-end key would not have collided`
  is [ADR-08](../docs/decisions/ADR-08-fence-by-shared-txid.md)'s generation bug in
  its new costume: it asserts the *wrong* design's failure, because the right one
  looks identical until two owners batch differently.

  Against a real bucket. The mechanism is conditional-write semantics and a mock
  would only confirm our own reading of them.
  """
  use ExUnit.Case, async: false

  import AshCell.ObjectStoreCase

  @moduletag :object_store
  @moduletag :capture_log

  alias AshCell.Stream, as: S

  setup :require_object_store

  setup %{store: store} do
    dir = Path.join(System.tmp_dir!(), "ash_cell_stream_#{System.unique_integer([:positive])}")

    start_supervised!(
      {AshCell,
       repo: AshCell.TestRepo,
       dir: dir,
       migrator: AshCell.StreamMigrations,
       store: store,
       owner: "node-a",
       snapshot: false}
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp repo_pid(cell) do
    {:ok, pid} = AshCell.Manager.ensure_started(cell)
    AshCell.Cell.repo_pid(pid)
  end

  defp payloads(entries), do: Enum.map(entries, & &1.payload)
  defp offsets(entries), do: Enum.map(entries, & &1.offset)

  describe "append and read from the cell" do
    test "offsets are dense and monotonic", %{store: store} do
      cell = unique_cell("stream_dense")

      for i <- 1..20, do: {:ok, ^i} = S.append(cell, "tokens", "tok-#{i}")

      {:ok, entries} = S.read(store, cell, "tokens", 0)
      assert offsets(entries) == Enum.to_list(1..20)
    end

    test "a read from any offset is the exact suffix", %{store: store} do
      cell = unique_cell("stream_suffix")
      for i <- 1..20, do: S.append(cell, "tokens", "tok-#{i}")

      {:ok, entries} = S.read(store, cell, "tokens", 13)
      assert payloads(entries) == Enum.map(14..20, &"tok-#{&1}")
    end

    test "appending a list allocates one contiguous run", %{store: store} do
      cell = unique_cell("stream_batch")

      {:ok, 3} = S.append(cell, "tokens", ["a", "b", "c"])
      {:ok, 5} = S.append(cell, "tokens", ["d", "e"])

      {:ok, entries} = S.read(store, cell, "tokens", 0)
      assert payloads(entries) == ~w(a b c d e)
    end

    test "streams in one cell have independent offsets", %{store: store} do
      cell = unique_cell("stream_independent")

      {:ok, 1} = S.append(cell, "left", "l1")
      {:ok, 1} = S.append(cell, "right", "r1")
      {:ok, 2} = S.append(cell, "left", "l2")

      {:ok, left} = S.read(store, cell, "left", 0)
      assert payloads(left) == ~w(l1 l2)
    end
  end

  describe "flush" do
    test "truncated entries read back byte-identically through segments", %{store: store} do
      cell = unique_cell("stream_flush")
      for i <- 1..50, do: S.append(cell, "tokens", "tok-#{i}")

      {:ok, %{start: 1, end: 50}} = S.flush(store, cell, "tokens", retain: 0)

      # Gone from the cell entirely, so the read below can only be coming from the
      # object store.
      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(
          repo_pid(cell),
          "SELECT COUNT(*) FROM ash_cell_stream_entries WHERE stream = ?",
          ["tokens"]
        )

      assert count == 0

      {:ok, entries} = S.read(store, cell, "tokens", 0)
      assert payloads(entries) == Enum.map(1..50, &"tok-#{&1}")
      assert offsets(entries) == Enum.to_list(1..50)
    end

    test "offsets do not restart after a truncation", %{store: store} do
      cell = unique_cell("stream_no_restart")

      for i <- 1..10, do: S.append(cell, "tokens", "tok-#{i}")
      {:ok, _} = S.flush(store, cell, "tokens", retain: 0)

      # `MAX(seq)` is 0 here. The watermark is the only thing that remembers.
      assert {:ok, 11} = S.append(cell, "tokens", "tok-11")

      {:ok, entries} = S.read(store, cell, "tokens", 0)
      assert offsets(entries) == Enum.to_list(1..11)
    end

    test "reads stitch a segment onto the unflushed tail", %{store: store} do
      cell = unique_cell("stream_stitch")

      for i <- 1..30, do: S.append(cell, "tokens", "tok-#{i}")
      {:ok, %{end: 30}} = S.flush(store, cell, "tokens", retain: 0)
      for i <- 31..40, do: S.append(cell, "tokens", "tok-#{i}")

      # Straddling the boundary in both directions.
      {:ok, all} = S.read(store, cell, "tokens", 0)
      assert offsets(all) == Enum.to_list(1..40)

      {:ok, across} = S.read(store, cell, "tokens", 25)
      assert payloads(across) == Enum.map(26..40, &"tok-#{&1}")

      {:ok, hot} = S.read(store, cell, "tokens", 35)
      assert payloads(hot) == Enum.map(36..40, &"tok-#{&1}")
    end

    test "a second flush starts where the first stopped", %{store: store} do
      cell = unique_cell("stream_second")

      for i <- 1..10, do: S.append(cell, "tokens", "tok-#{i}")
      {:ok, %{start: 1, end: 10}} = S.flush(store, cell, "tokens")
      for i <- 11..18, do: S.append(cell, "tokens", "tok-#{i}")

      assert {:ok, %{start: 11, end: 18}} = S.flush(store, cell, "tokens")
      assert {:ok, :nothing_to_flush} = S.flush(store, cell, "tokens")
    end

    test "retain keeps entries in the cell without changing what is read", %{store: store} do
      cell = unique_cell("stream_retain")
      for i <- 1..20, do: S.append(cell, "tokens", "tok-#{i}")

      {:ok, _} = S.flush(store, cell, "tokens", retain: 5)

      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(
          repo_pid(cell),
          "SELECT COUNT(*) FROM ash_cell_stream_entries WHERE stream = ?",
          ["tokens"]
        )

      assert count == 5

      {:ok, entries} = S.read(store, cell, "tokens", 0)
      assert offsets(entries) == Enum.to_list(1..20)
    end

    test "a reader that never touches the cell sees only what was flushed", %{store: store} do
      cell = unique_cell("stream_remote")

      for i <- 1..10, do: S.append(cell, "tokens", "tok-#{i}")
      {:ok, _} = S.flush(store, cell, "tokens", retain: 0)
      for i <- 11..15, do: S.append(cell, "tokens", "tok-#{i}")

      # `local?: false` is the reader on a node that does not own the cell. The
      # unflushed tail is genuinely not visible to it, and that is the RPO showing
      # through rather than a bug.
      {:ok, entries} = S.read(store, cell, "tokens", 0, local?: false)
      assert offsets(entries) == Enum.to_list(1..10)
    end
  end

  # Flushes in a tight loop until told to stop, counting the segments it wrote.
  defp flush_until_done(store, cell, count) do
    written =
      case S.flush(store, cell, "tokens", batch: 7, retain: 0) do
        {:ok, %{}} -> count + 1
        _ -> count
      end

    receive do
      :done -> written
    after
      0 -> flush_until_done(store, cell, written)
    end
  end

  describe "the segment set is not assumed to be a disjoint cover" do
    # Both of these guard a bug that was measured rather than imagined: the stitch
    # was written believing one offset could only ever come from one segment, and a
    # concurrent PUT made the store's listing return a key twice. A duplicate in a
    # resumed stream is a repeated word for a token stream and a repeated effect
    # for an event stream.
    test "overlapping segments read back contiguously, once each", %{store: store} do
      cell = unique_cell("stream_overlap")

      entries =
        Enum.map(1..12, fn i -> %{offset: i, payload: "tok-#{i}", at: 0} end)

      # A displaced writer and its successor holding different watermarks: one
      # writes the segment starting at 5 covering 5..12, the other the segment
      # starting at 9 covering 9..12. Different keys, so neither conditional write
      # is refused, and the start-only key does not fence this case.
      wide = Enum.slice(entries, 4..11)
      narrow = Enum.slice(entries, 8..11)

      {:ok, _} =
        AshCell.ObjectStore.put(
          store,
          S.segment_key(cell, "tokens", 5),
          S.encode_segment("tokens", 5, 12, wide),
          if_none_match: true
        )

      {:ok, _} =
        AshCell.ObjectStore.put(
          store,
          S.segment_key(cell, "tokens", 9),
          S.encode_segment("tokens", 9, 12, narrow),
          if_none_match: true
        )

      {:ok, read} = S.read(store, cell, "tokens", 4, local?: false)
      assert offsets(read) == Enum.to_list(5..12)
      assert payloads(read) == Enum.map(5..12, &"tok-#{&1}")
    end

    test "a duplicated key in the listing yields one copy of each offset", %{store: store} do
      cell = unique_cell("stream_dupe_listing")
      entries = Enum.map(1..5, fn i -> %{offset: i, payload: "tok-#{i}", at: 0} end)

      {:ok, _} =
        AshCell.ObjectStore.put(
          store,
          S.segment_key(cell, "tokens", 1),
          S.encode_segment("tokens", 1, 5, entries),
          if_none_match: true
        )

      # `segment_starts/3` de-duplicates, so the same start appearing twice in a
      # listing cannot make the segment be read twice.
      {:ok, read} = S.read(store, cell, "tokens", 0, local?: false)
      assert offsets(read) == Enum.to_list(1..5)
    end
  end

  describe "the stitch under concurrent flush" do
    @tag timeout: 120_000
    test "resume is exact while a flush runs", %{store: store} do
      cell = unique_cell("stream_race")
      total = 300
      appender = self()

      # Flush until the appender says it is finished, rather than a fixed number of
      # times. A fixed count finishes early and leaves the tail of the run
      # uncontended, which is the half where the reader is most likely to catch a
      # truncation mid-stitch.
      flusher =
        Task.async(fn ->
          send(appender, :flushing)
          flush_until_done(store, cell, 0)
        end)

      assert_receive :flushing, 5_000

      for i <- 1..total do
        {:ok, ^i} = S.append(cell, "tokens", "tok-#{i}")

        # Resume from a random earlier offset, exactly as a reconnecting client
        # does, while the flusher is truncating underneath.
        from = :rand.uniform(i) - 1
        {:ok, entries} = S.read(store, cell, "tokens", from, limit: total)

        unless offsets(entries) == Enum.to_list((from + 1)..i) do
          {:ok, keys} = AshCell.ObjectStore.list(store, S.segment_prefix(cell, "tokens"))

          segs =
            Enum.map(keys, fn key ->
              start = key |> Path.basename(".seg") |> String.to_integer()
              {:ok, seg} = S.decode_segment(elem(AshCell.ObjectStore.get(store, key), 1))
              {start, seg.end, length(seg.entries)}
            end)

          local =
            AshCell.with_cell(cell, fn ->
              AshCell.repo().query!(
                "SELECT seq FROM ash_cell_stream_entries WHERE stream = ? ORDER BY seq",
                ["tokens"]
              ).rows
              |> List.flatten()
            end)

          meta =
            AshCell.with_cell(cell, fn ->
              AshCell.repo().query!(
                "SELECT flushed_through, pending_start, pending_end FROM ash_cell_stream_meta WHERE stream = ?",
                ["tokens"]
              ).rows
            end)

          flunk("""
          resuming at #{from} with #{i} appended did not return the exact suffix
          got offsets : #{inspect(offsets(entries))}
          wanted      : #{inspect(Enum.to_list((from + 1)..i))}
          segments    : #{inspect(segs)}
          cell rows   : #{inspect(local)}
          meta        : #{inspect(meta)}
          """)
        end

        assert payloads(entries) == Enum.map((from + 1)..i, &"tok-#{&1}")
      end

      send(flusher.pid, :done)

      flushes = Task.await(flusher, 60_000)
      assert flushes >= 5, "the flusher wrote #{flushes} segments; the race never ran"

      {:ok, entries} = S.read(store, cell, "tokens", 0, limit: total)
      assert offsets(entries) == Enum.to_list(1..total)

      {:ok, watermark} = S.latest_offset(store, cell, "tokens")
      assert watermark >= 100, "only #{watermark} of #{total} entries ever reached a segment"
    end
  end

  describe "fencing" do
    test "a displaced writer's flush collides with its successor's", %{store: store} do
      cell = unique_cell("stream_fenced")
      for i <- 1..10, do: S.append(cell, "tokens", "tok-#{i}")

      # The successor got there first, from the same watermark, with its own batch.
      {:ok, _} =
        AshCell.ObjectStore.put(store, S.segment_key(cell, "tokens", 1), "successor's bytes",
          if_none_match: true
        )

      assert {:error, :fenced} = S.flush(store, cell, "tokens")

      # Fail closed: the cell stops being served, rather than accumulating writes
      # that can never be shipped. ADR-10.
      assert Map.has_key?(AshCell.Manager.quarantined(), cell)
    end

    test "a start-end key would not have collided", %{store: store} do
      # The design that looks equivalent and fences nothing. Two owners flushing
      # from the same watermark with different batch sizes address different keys,
      # both conditional writes succeed, and the loser is acknowledged before being
      # superseded. This is why the key is the start offset alone.
      cell = unique_cell("stream_start_end")
      prefix = S.segment_prefix(cell, "tokens")

      assert {:ok, _} =
               AshCell.ObjectStore.put(store, "#{prefix}000001-000150.seg", "displaced",
                 if_none_match: true
               )

      assert {:ok, _} =
               AshCell.ObjectStore.put(store, "#{prefix}000001-000200.seg", "successor",
                 if_none_match: true
               )

      # Where the shipped design refuses the second writer outright.
      assert {:ok, _} =
               AshCell.ObjectStore.put(store, S.segment_key(cell, "tokens", 1), "displaced",
                 if_none_match: true
               )

      assert {:error, :precondition_failed} =
               AshCell.ObjectStore.put(store, S.segment_key(cell, "tokens", 1), "successor",
                 if_none_match: true
               )
    end
  end

  describe "a crash between the PUT and the local commit" do
    setup %{store: store} do
      cell = unique_cell("stream_pending")
      for i <- 1..10, do: S.append(cell, "tokens", "tok-#{i}")

      {:ok, entries} = S.read(store, cell, "tokens", 0)
      body = S.encode_segment("tokens", 1, 10, entries)

      {:ok, cell: cell, body: body}
    end

    defp mark_pending(cell, digest) do
      Ecto.Adapters.SQL.query!(
        repo_pid(cell),
        "UPDATE ash_cell_stream_meta SET pending_start = 1, pending_end = 10, pending_digest = ? WHERE stream = ?",
        [digest, "tokens"]
      )
    end

    defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    test "adopts the segment when the PUT landed", %{store: store, cell: cell, body: body} do
      {:ok, _} =
        AshCell.ObjectStore.put(store, S.segment_key(cell, "tokens", 1), body,
          if_none_match: true
        )

      mark_pending(cell, digest(body))

      # Our own write finishing late. Adopt it rather than re-flushing over it.
      assert {:ok, :nothing_to_flush} = S.flush(store, cell, "tokens", retain: 0)

      {:ok, entries} = S.read(store, cell, "tokens", 0)
      assert offsets(entries) == Enum.to_list(1..10)
      refute Map.has_key?(AshCell.Manager.quarantined(), cell)
    end

    test "re-flushes when the PUT never landed", %{store: store, cell: cell, body: body} do
      mark_pending(cell, digest(body))

      assert {:ok, %{start: 1, end: 10}} = S.flush(store, cell, "tokens", retain: 0)

      {:ok, entries} = S.read(store, cell, "tokens", 0)
      assert payloads(entries) == Enum.map(1..10, &"tok-#{&1}")
    end

    test "fences when the segment is somebody else's", %{store: store, cell: cell, body: body} do
      {:ok, _} =
        AshCell.ObjectStore.put(store, S.segment_key(cell, "tokens", 1), "successor's bytes",
          if_none_match: true
        )

      mark_pending(cell, digest(body))

      assert {:error, :fenced} = S.flush(store, cell, "tokens")
      assert Map.has_key?(AshCell.Manager.quarantined(), cell)
    end
  end

  describe "adoption" do
    test "takes the watermark from the store, not from the restored file", %{store: store} do
      cell = unique_cell("stream_adopt")

      for i <- 1..10, do: S.append(cell, "tokens", "tok-#{i}")
      {:ok, _} = S.flush(store, cell, "tokens", retain: 0)

      # A predecessor shipped past what this file knows about: rewind the local
      # watermark to stand in for a snapshot restored from before that flush.
      Ecto.Adapters.SQL.query!(
        repo_pid(cell),
        "UPDATE ash_cell_stream_meta SET flushed_through = 4 WHERE stream = ?",
        ["tokens"]
      )

      assert {:ok, 10} = S.adopt(store, cell, "tokens")

      # Without adoption the next flush would start at 5 and step over the
      # predecessor's segment instead of colliding with it.
      assert {:ok, 11} = S.append(cell, "tokens", "tok-11")
    end

    test "latest_offset is 0 for a stream that has never flushed", %{store: store} do
      assert {:ok, 0} = S.latest_offset(store, unique_cell("stream_virgin"), "tokens")
    end
  end
end
