defmodule AshCell.ReadCacheTest do
  @moduledoc """
  The cache's whole value rests on it never serving a value older than the last
  commit, so these tests are about ordering rather than about speed.
  """
  use ExUnit.Case, async: false

  alias AshCell.ReadCache

  setup do
    start_supervised!(ReadCache)
    cell = "cell_#{System.unique_integer([:positive])}"
    {:ok, cell: cell}
  end

  describe "fetch and read" do
    test "a cold cache misses", %{cell: cell} do
      assert ReadCache.fetch(cell, :pointer) == :miss
    end

    test "read populates on a miss and does not rebuild on a hit", %{cell: cell} do
      builds = counter()

      assert ReadCache.read(cell, :pointer, fn -> count(builds, "release-42") end) == "release-42"
      assert ReadCache.read(cell, :pointer, fn -> count(builds, "release-42") end) == "release-42"

      assert reads(builds) == 1
      assert ReadCache.fetch(cell, :pointer) == {:ok, "release-42"}
    end

    test "projections are separate entries", %{cell: cell} do
      ReadCache.read(cell, :pointer, fn -> "release-42" end)
      ReadCache.read(cell, :rollout, fn -> 10 end)

      assert ReadCache.fetch(cell, :pointer) == {:ok, "release-42"}
      assert ReadCache.fetch(cell, :rollout) == {:ok, 10}
    end

    test "one cell's entries are not another's", %{cell: cell} do
      other = cell <> "_other"

      ReadCache.read(cell, :pointer, fn -> "release-42" end)

      assert ReadCache.fetch(other, :pointer) == :miss
    end
  end

  describe "invalidation" do
    test "invalidate drops the entry", %{cell: cell} do
      ReadCache.read(cell, :pointer, fn -> "release-42" end)

      ReadCache.invalidate(cell)

      assert ReadCache.fetch(cell, :pointer) == :miss
    end

    test "invalidate leaves other cells alone", %{cell: cell} do
      other = cell <> "_other"
      ReadCache.read(cell, :pointer, fn -> "a" end)
      ReadCache.read(other, :pointer, fn -> "b" end)

      ReadCache.invalidate(cell)

      assert ReadCache.fetch(cell, :pointer) == :miss
      assert ReadCache.fetch(other, :pointer) == {:ok, "b"}
    end

    test "a write brackets its statement: cold before, cold after", %{cell: cell} do
      ReadCache.read(cell, :pointer, fn -> "release-42" end)

      ReadCache.writing(cell, fn ->
        assert ReadCache.fetch(cell, :pointer) == :miss
      end)

      assert ReadCache.fetch(cell, :pointer) == :miss
    end
  end

  describe "publishing under an open write" do
    test "is refused, so a pre-commit projection cannot be left behind", %{cell: cell} do
      # The interleaving that the second epoch bump exists for: a reader computes
      # from the state a write has not committed yet, and tries to publish it.
      ReadCache.writing(cell, fn ->
        epoch = ReadCache.epoch(cell)
        assert ReadCache.publish(cell, :pointer, "pre-commit", epoch) == :stale
      end)

      assert ReadCache.fetch(cell, :pointer) == :miss
    end

    test "a projection built before a write is dropped when published after it", %{cell: cell} do
      epoch = ReadCache.epoch(cell)

      ReadCache.writing(cell, fn -> :wrote end)

      assert ReadCache.publish(cell, :pointer, "stale", epoch) == :stale
      assert ReadCache.fetch(cell, :pointer) == :miss
    end

    test "a read racing a write does not leave the pre-write value cached", %{cell: cell} do
      # Reader captures the epoch and is slow to build; the write lands in the gap.
      epoch = ReadCache.epoch(cell)
      ReadCache.writing(cell, fn -> :wrote end)

      assert ReadCache.publish(cell, :pointer, "release-41", epoch) == :stale

      assert ReadCache.read(cell, :pointer, fn -> "release-42" end) == "release-42"
    end
  end

  describe "a writer that dies" do
    test "ends its write, so publishing works again", %{cell: cell} do
      parent = self()

      pid =
        spawn(fn ->
          ReadCache.begin_write(cell)
          send(parent, :writing)
          Process.sleep(:infinity)
        end)

      assert_receive :writing

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      # The epoch has to be re-read: the DOWN bumped it, which is the point.
      epoch = ReadCache.epoch(cell)
      assert ReadCache.publish(cell, :pointer, "release-42", epoch) == :ok
    end

    test "does not leave a stale entry publishable", %{cell: cell} do
      ReadCache.read(cell, :pointer, fn -> "release-41" end)
      parent = self()

      pid =
        spawn(fn ->
          ReadCache.begin_write(cell)
          send(parent, :writing)
          Process.sleep(:infinity)
        end)

      assert_receive :writing
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}

      assert ReadCache.fetch(cell, :pointer) == :miss
    end
  end

  describe "writing/2" do
    test "returns the function's value", %{cell: cell} do
      assert ReadCache.writing(cell, fn -> {:ok, 7} end) == {:ok, 7}
    end

    test "invalidates even when the statement raises", %{cell: cell} do
      ReadCache.read(cell, :pointer, fn -> "release-41" end)

      assert_raise RuntimeError, fn ->
        ReadCache.writing(cell, fn -> raise "boom" end)
      end

      # A raised write is not proof the write did not land.
      assert ReadCache.fetch(cell, :pointer) == :miss
      epoch = ReadCache.epoch(cell)
      assert ReadCache.publish(cell, :pointer, "release-42", epoch) == :ok
    end

    test "nests without leaving a write open", %{cell: cell} do
      ReadCache.writing(cell, fn ->
        ReadCache.writing(cell, fn -> :inner end)
      end)

      epoch = ReadCache.epoch(cell)
      assert ReadCache.publish(cell, :pointer, "release-42", epoch) == :ok
    end
  end

  defp counter, do: :counters.new(1, [])
  defp count(counter, value), do: :counters.add(counter, 1, 1) && value
  defp reads(counter), do: :counters.get(counter, 1)
end
