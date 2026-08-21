defmodule Rollout.ConsistencyTest do
  @moduledoc """
  The claim the demo is built to support: a rollback is visible to the next
  check-in, and no check-in ever sees a pointer the cell has moved off.

  These are ordering tests. `AshCell.ReadCacheTest` proves the cache's invalidation
  rules in isolation; these prove that the resolve path built on top of them cannot
  serve a superseded release, including while a promotion is in flight and including
  under concurrent readers.
  """
  use Rollout.ChannelCase, async: false

  setup %{channel: channel} do
    {:ok, one} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
    {:ok, two} = Control.cut(channel, "1.1.0", artifacts("1.1.0"))
    {:ok, _} = Control.promote(channel, one.id)
    {:ok, one: one, two: two}
  end

  test "a resolve is served from cache after the first one", %{channel: channel} do
    assert AshCell.ReadCache.fetch(channel, :manifest) == :miss

    Resolve.check(channel, checkin("device-1"))

    assert {:ok, _manifest} = AshCell.ReadCache.fetch(channel, :manifest)
  end

  test "a promotion drops the cached manifest", %{channel: channel, two: two} do
    Resolve.check(channel, checkin("device-1"))
    assert {:ok, _} = AshCell.ReadCache.fetch(channel, :manifest)

    {:ok, _} = Control.promote(channel, two.id)

    assert AshCell.ReadCache.fetch(channel, :manifest) == :miss
  end

  test "every check-in after a rollback returns the old release", %{
    channel: channel,
    one: one,
    two: two
  } do
    one_id = one.id
    {:ok, _} = Control.promote(channel, two.id)

    # Warm the cache hard, so a stale entry would have every chance to survive.
    for n <- 1..200, do: Resolve.check(channel, checkin("device-#{n}"))

    {:ok, _} = Control.rollback(channel)

    for n <- 1..200 do
      assert {:update, %{release_id: ^one_id}} = Resolve.check(channel, checkin("device-#{n}"))
    end
  end

  test "concurrent readers never see the pointer go backwards", %{
    channel: channel,
    one: one,
    two: two
  } do
    one_id = one.id
    two_id = two.id
    parent = self()

    readers =
      for _ <- 1..16 do
        spawn_link(fn -> read_until_told(parent, channel, []) end)
      end

    {:ok, _} = Control.promote(channel, two_id)
    {:ok, _} = Control.rollback(channel)
    {:ok, _} = Control.promote(channel, two_id)

    for reader <- readers, do: send(reader, {:stop, self()})

    observations =
      for _ <- readers do
        assert_receive {:observed, seen}, 5_000
        seen
      end

    # Every reader's sequence has to be a subsequence of the writer's: the pointer
    # moved 1.0 -> 1.1 -> 1.0 -> 1.1, so a reader may miss transitions but must
    # never observe one that did not happen in that order.
    for seen <- observations do
      assert subsequence?(collapse(seen), [one_id, two_id, one_id, two_id])
    end
  end

  test "a manifest built before a promotion cannot be published after it", %{
    channel: channel,
    two: two
  } do
    # The interleaving the second epoch bump exists for, driven through the real
    # resolve path rather than the cache's own API.
    epoch = AshCell.ReadCache.epoch(channel)
    stale = Resolve.build(channel)

    {:ok, _} = Control.promote(channel, two.id)

    assert AshCell.ReadCache.publish(channel, :manifest, stale, epoch) == :stale
    assert Resolve.manifest(channel).release_id == two.id
  end

  test "a rolled back transaction leaves the pointer and the cache untouched", %{
    channel: channel,
    one: one,
    two: two
  } do
    one_id = one.id
    Resolve.check(channel, checkin("device-1"))

    {:error, :abandoned} =
      AshCell.transaction(channel, fn ->
        Control.promote(channel, two.id)
        AshCell.rollback(:abandoned)
      end)

    assert Control.current_pointer(channel).release_id == one_id
    assert {:update, %{release_id: ^one_id}} = Resolve.check(channel, checkin("device-1"))
  end

  defp read_until_told(parent, channel, seen) do
    receive do
      {:stop, _from} ->
        send(parent, {:observed, Enum.reverse(seen)})
    after
      0 ->
        observation =
          case Resolve.check(channel, checkin("device-loop")) do
            {:update, %{release_id: id}} -> id
            other -> other
          end

        read_until_told(parent, channel, [observation | seen])
    end
  end

  defp collapse(seen), do: Enum.dedup(seen)

  defp subsequence?([], _), do: true
  defp subsequence?(_, []), do: false
  defp subsequence?([h | t], [h | rest]), do: subsequence?(t, rest)
  defp subsequence?(seen, [_ | rest]), do: subsequence?(seen, rest)
end
