defmodule Relay.ResumeTest do
  @moduledoc """
  What survives the writer.

  Three claims, in increasing order of how much has been taken away:

    1. the process producing the stream is killed mid-token, and a reader resumes
       at the offset it had;
    2. the cell is closed, so the resume has to reopen it;
    3. the cell's file is deleted, so the segments in the bucket are all there is.

  The third is the one worth having. Everything before it could pass with the
  entries never leaving local disk.

  Against a real bucket — the resume path is conditional writes and object listing,
  and a mock would only confirm our own reading of them.
  """
  use ExUnit.Case, async: false

  alias Relay.{Cells, Streams}

  @moduletag :object_store
  @moduletag :capture_log

  setup do
    unless Cells.store() do
      raise "relay's tests need an object store; see the README"
    end

    :ok
  end

  # Wall-clock in the name, not just a counter: the bucket outlives the VM, so a
  # name built from `unique_integer/1` alone inherits a previous run's segments.
  defp new_id, do: "test_#{System.system_time(:nanosecond)}_#{System.unique_integer([:positive])}"

  defp await_offset(id, target, deadline \\ 5_000) do
    started = System.monotonic_time(:millisecond)
    do_await(id, target, started, deadline)
  end

  defp do_await(id, target, started, deadline) do
    {:ok, %{through: through}} = Streams.resume(id, 0)

    cond do
      through >= target ->
        through

      System.monotonic_time(:millisecond) - started > deadline ->
        flunk("stream #{id} only reached offset #{through}, wanted #{target}")

      true ->
        Process.sleep(20)
        do_await(id, target, started, deadline)
    end
  end

  defp text(entries), do: Enum.map_join(entries, "", & &1.payload)

  test "a reader resumes at its offset after the generator is killed" do
    id = new_id()
    {:ok, ^id} = Streams.start("a prompt", id: id, tokens: 200, interval: 1, flush_every: 10)

    await_offset(id, 40)
    {:ok, %{entries: seen, through: through}} = Streams.resume(id, 0)
    assert through >= 40

    Streams.kill(id)
    refute_eventually(fn -> Streams.generating?(id) end)

    # The client comes back holding nothing but its offset.
    {:ok, %{entries: rest}} = Streams.resume(id, through)

    # No gap, no repeat: the suffix starts exactly one past where the client was,
    # and concatenating the two halves is the stream.
    if rest != [] do
      assert hd(rest).offset == through + 1
    end

    {:ok, %{entries: whole}} = Streams.resume(id, 0)
    assert text(seen) <> text(rest) == text(whole)
    assert Enum.map(whole, & &1.offset) == Enum.to_list(1..length(whole))
  end

  test "a resume reopens a closed cell" do
    id = new_id()
    {:ok, ^id} = Streams.start("a prompt", id: id, tokens: 60, interval: 1, flush_every: 10)

    await_offset(id, 30)
    Streams.kill(id)
    {:ok, %{entries: before}} = Streams.resume(id, 0)

    :ok = Streams.evict(id)

    {:ok, %{entries: after_evict}} = Streams.resume(id, 0)
    assert text(after_evict) == text(before)
  end

  test "a resume is served from the bucket when the cell's file is gone" do
    id = new_id()
    {:ok, ^id} = Streams.start("a prompt", id: id, tokens: 60, interval: 1, flush_every: 10)

    await_offset(id, 40)
    Streams.kill(id)

    # Flush everything, so what is about to be deleted is genuinely redundant.
    {:ok, _} = Streams.flush(id)
    {:ok, %{entries: before}} = Streams.resume(id, 0)
    {:ok, tiers} = Streams.tiers(id)
    assert tiers.in_cell == 0, "#{tiers.in_cell} entries never reached the bucket"

    # The node that was serving this stream is gone, and so is its disk.
    {:ok, _removed} = Streams.evict(id, delete: true)
    refute File.exists?(AshCell.path_for(Cells.cell_key(id)))

    {:ok, %{entries: recovered}} =
      AshCell.Stream.read(Cells.store(), Cells.cell_key(id), Cells.stream(), 0, local?: false)
      |> then(fn {:ok, entries} -> {:ok, %{entries: entries}} end)

    assert text(recovered) == text(before)
    assert Enum.map(recovered, & &1.offset) == Enum.map(before, & &1.offset)
  end

  test "offsets do not restart when a killed generation is taken over" do
    id = new_id()
    {:ok, ^id} = Streams.start("a prompt", id: id, tokens: 40, interval: 1, flush_every: 5)

    await_offset(id, 25)
    Streams.kill(id)
    refute_eventually(fn -> Streams.generating?(id) end)

    {:ok, %{through: through}} = Streams.resume(id, 0)

    # A second generator picks the stream up. It must continue the offset
    # namespace, not reissue it — the entries below the watermark have been
    # truncated out of the cell, so `MAX(seq)` alone would send it back to 1.
    {:ok, ^id} = Streams.start("continued", id: id, tokens: 10, interval: 1, flush_every: 5)
    await_offset(id, through + 5)

    {:ok, %{entries: whole}} = Streams.resume(id, 0)
    offsets = Enum.map(whole, & &1.offset)
    assert offsets == Enum.uniq(offsets)
    assert offsets == Enum.to_list(1..length(whole))
  end

  defp refute_eventually(fun, remaining \\ 100) do
    cond do
      not fun.() -> :ok
      remaining == 0 -> flunk("condition stayed true")
      true -> Process.sleep(20) && refute_eventually(fun, remaining - 1)
    end
  end
end
