# Probe: should AshCell.ReadCache keep projections in :persistent_term or in ETS?
#
# scripts/read_pool_probe.exs settled the question above SQLite -- a cell's reads
# serialise on one connection, so hot reads have to be cached somewhere -- and it
# measured :persistent_term against that, winning by three orders of magnitude. What
# it never measured is the other side of the trade: what invalidation costs.
#
# That asymmetry is the whole question. A :persistent_term read is a pointer into a
# literal area shared by the whole VM: no lock, no copy. Erasing or replacing that
# term schedules a literal-area cleanup across *every process that references it*,
# because the area cannot be freed while anyone points into it. So the read is priced
# by nothing and the invalidation is priced by the size of the node rather than the
# size of the cell. ETS inverts both: the read copies onto the reader's heap, and the
# delete is local to one table.
#
#     mix run scripts/read_cache_store_probe.exs
#
# Four sections, because the decision needs all four:
#
#   A. read cost by projection size  -- what ETS would cost us
#   B. invalidation by reader count  -- what :persistent_term costs us
#   C. the walk inside bump/1        -- what today's implementation costs a fleet
#                                       that has never cached anything
#   D. the write bracket end to end  -- both, through the real code path
#
# On B: the cleanup is scheduled, not synchronous, so the erase call can return long
# before the work is done. Each round therefore reports the call, and the call plus a
# barrier -- a ping to every reader, awaited -- alongside the barrier's own cost with
# no erase at all, so the barrier is not mistaken for the finding.

defmodule CacheStoreProbe do
  @readers 32
  @reads_per_reader 500
  @writers 32
  @brackets 500
  @rounds 20
  @reps 5

  @tab :read_cache_store_probe

  def run do
    :erlang.system_flag(:scheduler_wall_time, true)

    # read_concurrency only, deliberately. write_concurrency splits a table into
    # per-bucket locks, so a whole-table operation has to take all of them -- and
    # :ets.match_delete/2 with a partially bound key is a whole-table operation. That
    # pairing measured 36 us a bracket, which is section D's first finding.
    :ets.new(@tab, [:set, :public, :named_table, read_concurrency: true])

    IO.puts("""

    OTP #{:erlang.system_info(:otp_release)}, \
    #{:erlang.system_info(:schedulers_online)} schedulers online, \
    median of #{@reps}

    A. read cost -- #{@readers} concurrent readers x #{@reads_per_reader} reads each

       The one column :persistent_term wins. An ETS read copies the term onto the
       reader's heap, so the gap should widen with the projection.
    """)

    for shape <- [:pointer, :manifest, :large] do
      value = projection(shape)
      key = {:probe, shape}

      :persistent_term.put(key, value)
      :ets.insert(@tab, {key, value})

      IO.puts("   #{label(shape)} #{:erts_debug.size(value)} words")
      reads("     :persistent_term", fn -> :persistent_term.get(key) end)
      reads("     ETS", fn -> :ets.lookup(@tab, key) end)

      :persistent_term.erase(key)
      :ets.delete(@tab, key)
    end

    IO.puts("""

    B. invalidating one projection, by how many processes hold a reference to it

       Every reader has read the term and is otherwise idle, which is what a node
       looks like once the cache is warm: holding it costs one word, because
       :persistent_term.get/1 does not copy. Erasing it is what makes the VM copy the
       literal onto each of those heaps before the area can be freed.

       Each round is: publish, have every holder read it, erase, have every holder
       read again. Wall time cannot answer this on its own -- the cleanup is
       scheduled rather than synchronous, and the barrier that makes it observable
       costs more than the thing being measured once there are thousands of holders.
       So the column that decides it is CPU busy across all schedulers, which counts
       work wherever it landed. Both stores run an identical barrier and identical
       reads, so ETS is the control and the ratio is the literal-area cleanup.

       The last column is the difference from the ETS row per round, not a ratio:
       the barrier's CPU is in both, so subtracting it is what isolates the cleanup.

       holders            store          wall     CPU busy    per round   cleanup/round
    """)

    for holders <- [0, 100, 1_000, 10_000] do
      invalidation(holders)
    end

    IO.puts("""

    C. one bump/1, by total :persistent_term table size

       AshCell.ReadCache.bump/1 finds a cell's entries by walking
       :persistent_term.get() -- the whole VM-wide table, shared with every
       dependency. It runs twice per write, for every cell, whether or not that cell
       has ever published a projection. ETS finds them with a match on one table.
    """)

    for size <- [10, 100, 1_000, 10_000] do
      fill(size)
      report("     #{pad(size)} entries: walk, as bump/1 does", fn -> walk("acme") end)
      report("     #{pad(size)} entries: ETS match_delete", fn -> match_delete("acme") end)
      clear()
    end

    IO.puts("""

    D. the write bracket end to end

       The real AshCell.ReadCache.writing/2 against the same job in ETS. Both
       invalidate before the statement and after it. The difference is not only the
       store: today's bracket is two GenServer.call/2 round trips through one process
       for the entire fleet, and in ETS the invalidation half needs no process at all.
       (Monitoring writers still does, and is not on this path.)

       Measured on an empty cache, which is the common case: most cells in a fleet
       publish no projection at all and pay this anyway.
    """)

    {:ok, _} = AshCell.ReadCache.start_link([])

    for kind <- [:read_cache, :ets_match, :ets_key] do
      report("     #{@brackets} sequential: #{bracket_label(kind)}", fn -> sequential(kind) end)
    end

    for kind <- [:read_cache, :ets_match, :ets_key] do
      report("     #{@writers} concurrent: #{bracket_label(kind)}", fn -> concurrent(kind) end)
    end

    IO.puts("")
  end

  # Shaped after Rollout.Resolve's manifest: the pointer a device is told about plus
  # the artifacts it has to fetch. :large is the same projection for a release with a
  # full per-platform asset split, where an ETS copy should start to hurt.
  defp projection(:pointer), do: "release-42"
  defp projection(:manifest), do: manifest(12)
  defp projection(:large), do: manifest(200)

  defp manifest(artifacts) do
    %{
      release_id: "0191f0c2-6f1e-7c3a-9a5e-2f4b1d8e77aa",
      version: "1.2.1",
      rollout: 25,
      artifacts:
        for a <- 1..artifacts do
          %{
            kind: Enum.at(~w[bundle asset map], rem(a, 3)),
            platform: Enum.at(~w[ios android], rem(a, 2)),
            arch: Enum.at(~w[arm64 x86_64], rem(div(a, 2), 2)),
            min_runtime: 140 + rem(a, 5),
            blob_hash: :crypto.hash(:sha256, "artifact-#{a}") |> Base.encode16(case: :lower),
            size: 1_000 * a
          }
        end
    }
  end

  defp label(:pointer), do: "pointer  --"
  defp label(:manifest), do: "manifest --"
  defp label(:large), do: "large    --"

  defp pad(n), do: String.pad_leading("#{n}", 5)

  ## A

  defp reads(label, read) do
    burst = fn ->
      1..@readers
      |> Task.async_stream(fn _ -> Enum.each(1..@reads_per_reader, fn _ -> read.() end) end,
        max_concurrency: @readers,
        timeout: :infinity
      )
      |> Stream.run()
    end

    micros = median(burst)
    total = @readers * @reads_per_reader

    IO.puts(
      String.pad_trailing(label, 26) <>
        String.pad_leading(format(micros), 12) <>
        String.pad_leading("#{Float.round(micros / total, 3)} µs/read", 18) <>
        String.pad_leading("#{round(total / (micros / 1_000_000))} reads/s", 18)
    )
  end

  ## B

  defp invalidation(holders) do
    key = {:probe, :churn}
    value = projection(:manifest)

    readers = for _ <- 1..holders//1, do: spawn(fn -> reader_loop(key) end)

    results =
      for store <- [:persistent_term, :ets], into: %{} do
        # Warm first, then one measured run: the CPU figure has to come from a single
        # interval, and taking the median of wall time would mean the two columns
        # described different runs.
        rounds(readers, key, value, store)
        {store, busy_and_wall(fn -> rounds(readers, key, value, store) end)}
      end

    for store <- [:persistent_term, :ets] do
      {busy, wall} = results[store]
      {ets_busy, _} = results[:ets]

      IO.puts(
        String.pad_leading("#{holders}", 14) <>
          String.pad_leading(store_label(store), 18) <>
          String.pad_leading(format(wall), 14) <>
          String.pad_leading(format(busy), 14) <>
          String.pad_leading(format(round(busy / @rounds)), 13) <>
          String.pad_leading(cleanup(store, busy - ets_busy), 16)
      )
    end

    Enum.each(readers, &Process.exit(&1, :kill))
    :persistent_term.erase(key)
    :ets.delete(@tab, key)
  end

  # Holders re-read on every round, so the reference each one carries is to the value
  # about to be erased rather than to one already copied onto its heap. Without that,
  # only the first erase of a run would be expensive and a sustained rate would look
  # free.
  defp rounds(readers, key, value, store) do
    time(fn ->
      Enum.each(1..@rounds, fn _ ->
        put(store, key, value)
        ping(readers)
        erase(store, key)
        ping(readers)
      end)
    end)
  end

  defp put(:persistent_term, key, value), do: :persistent_term.put(key, value)
  defp put(:ets, key, value), do: :ets.insert(@tab, {key, value})

  defp erase(:persistent_term, key), do: :persistent_term.erase(key)
  defp erase(:ets, key), do: :ets.delete(@tab, key)

  # A negative difference means the barrier moved more between the two runs than the
  # cleanup being measured. Saying so is the finding; printing the number would not be.
  defp cleanup(:ets, _delta), do: "control"
  defp cleanup(_store, delta) when delta <= 0, do: "swamped"
  defp cleanup(_store, delta), do: format(round(delta / @rounds))

  defp store_label(:persistent_term), do: ":persistent_term"
  defp store_label(:ets), do: "ETS"

  # A process that reads the cache when asked and is otherwise idle. It answers the
  # ping *after* reading, so a ping round trip is also the barrier: a process cannot
  # reply until it has finished the literal-area work the erase gave it.
  #
  # It reads only :persistent_term. An ETS lookup here copies the projection onto every
  # holder's heap on every ping, and that copy was most of the barrier's cost -- which
  # is what drowned the signal in the first version of this section. The ETS run does
  # the same reads, so it is still a control.
  defp reader_loop(key) do
    receive do
      {:read, from} ->
        _ = :persistent_term.get(key, :miss)
        send(from, :ok)
        reader_loop(key)
    end
  end

  defp ping([]), do: :ok

  defp ping(readers) do
    Enum.each(readers, &send(&1, {:read, self()}))
    Enum.each(readers, fn _ -> receive do: (:ok -> :ok) end)
  end

  ## C

  defp walk(cell_key) do
    for {{AshCell.ReadCache, ^cell_key, _name} = key, _} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end
  end

  defp match_delete(cell_key) do
    :ets.match_delete(@tab, {{AshCell.ReadCache, cell_key, :_}, :_})
  end

  defp fill(size) do
    value = projection(:manifest)

    for i <- 1..size do
      key = {AshCell.ReadCache, "filler-#{i}", :projection}
      :persistent_term.put(key, value)
      :ets.insert(@tab, {key, value})
    end
  end

  defp clear do
    for {{AshCell.ReadCache, _, _} = key, _} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :ets.match_delete(@tab, {{AshCell.ReadCache, :_, :_}, :_})
  end

  ## D

  defp sequential(kind) do
    Enum.each(1..@brackets, fn i -> bracket(kind, "cell-#{i}") end)
  end

  defp concurrent(kind) do
    1..@writers
    |> Task.async_stream(fn i -> bracket(kind, "cell-#{i}") end,
      max_concurrency: @writers,
      timeout: :infinity
    )
    |> Stream.run()
  end

  defp bracket(:read_cache, cell_key) do
    AshCell.ReadCache.writing(cell_key, fn -> :ok end)
  end

  # The ETS shape, twice over. match_delete finds a cell's projections without
  # knowing their names, which costs a table scan. Deleting by exact key needs the
  # GenServer to track what a cell has published -- which it does not today, but
  # could -- and that is the difference between a scan and one bucket.
  defp bracket(:ets_match, cell_key) do
    match_delete(cell_key)

    try do
      :ok
    after
      match_delete(cell_key)
    end
  end

  defp bracket(:ets_key, cell_key) do
    key_delete(cell_key)

    try do
      :ok
    after
      key_delete(cell_key)
    end
  end

  defp key_delete(cell_key) do
    :ets.delete(@tab, {AshCell.ReadCache, cell_key, :manifest})
  end

  defp bracket_label(:read_cache), do: "ReadCache"
  defp bracket_label(:ets_match), do: "ETS match_delete"
  defp bracket_label(:ets_key), do: "ETS delete by key"

  ## Reporting

  defp report(label, fun) do
    IO.puts(String.pad_trailing(label, 40) <> String.pad_leading(format(median(fun)), 12))
  end

  # Median of @reps after a warm-up, so one scheduler hiccup does not become the
  # headline.
  defp median(fun) do
    time(fun)

    1..@reps
    |> Enum.map(fn _ -> time(fun) end)
    |> Enum.sort()
    |> Enum.at(div(@reps, 2))
  end

  defp time(fun) do
    {micros, _} = :timer.tc(fun)
    micros
  end

  # {CPU busy across all schedulers, wall} for one run. The literal-area cleanup is
  # charged to whichever process the VM makes do it, so summing scheduler active time
  # is the only way to see work that never appears in the caller's wall clock.
  defp busy_and_wall(fun) do
    before = busy()
    wall = time(fun)
    {busy() - before, wall}
  end

  defp busy do
    :erlang.statistics(:scheduler_wall_time)
    |> Enum.map(fn {_id, active, _total} ->
      :erlang.convert_time_unit(active, :native, :microsecond)
    end)
    |> Enum.sum()
  end

  defp format(micros) when micros < 1_000, do: "#{micros} µs"
  defp format(micros), do: "#{Float.round(micros / 1000, 2)} ms"
end

CacheStoreProbe.run()
