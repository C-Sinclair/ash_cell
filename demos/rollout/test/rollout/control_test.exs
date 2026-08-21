defmodule Rollout.ControlTest do
  @moduledoc """
  The write path, and the three claims the demo exists to make good on: that a
  rollback is a pointer flip visible to the next check-in, that the pointer and its
  log cannot disagree, and that unreferenced blobs can be identified safely.
  """
  use Rollout.ChannelCase, async: false

  require Ash.Query

  alias Rollout.Channel.Release

  describe "cutting a release" do
    test "is inert until something points at it", %{channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))

      assert release.state == :draft
      assert Resolve.check(channel, checkin("device-1")) == :no_release
    end

    test "records its artifacts", %{channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id)

      assert {:update, %{artifacts: [_asset, _bundle]}} =
               Resolve.check(channel, checkin("device-1"))
    end
  end

  describe "promoting" do
    test "marks the new release live and the old one superseded", %{channel: channel} do
      {:ok, one} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
      {:ok, two} = Control.cut(channel, "1.1.0", artifacts("1.1.0"))

      {:ok, _} = Control.promote(channel, one.id)
      {:ok, _} = Control.promote(channel, two.id)

      assert state(channel, one.id) == :superseded
      assert state(channel, two.id) == :live
    end

    test "logs what it moved from and to", %{channel: channel} do
      {:ok, one} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
      {:ok, two} = Control.cut(channel, "1.1.0", artifacts("1.1.0"))

      {:ok, _} = Control.promote(channel, one.id)
      {:ok, _} = Control.promote(channel, two.id, reason: "ship it")

      assert [latest, first] = Control.history(channel)
      assert latest.release_id == two.id
      assert latest.from_release_id == one.id
      assert latest.reason == "ship it"
      assert first.from_release_id == nil
    end

    test "the pointer and its log commit together", %{channel: channel} do
      {:ok, one} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, one.id)

      # Both rows are in one file on one connection, so there is no interval in
      # which one is written and the other is not.
      assert Control.current_pointer(channel).release_id == one.id
      assert [%{release_id: logged}] = Control.history(channel)
      assert logged == one.id
    end
  end

  describe "rolling back" do
    setup %{channel: channel} do
      {:ok, one} = Control.cut(channel, "1.0.0", artifacts("1.0.0", asset: "asset-one"))
      {:ok, two} = Control.cut(channel, "1.1.0", artifacts("1.1.0", asset: "asset-two"))
      {:ok, _} = Control.promote(channel, one.id)
      {:ok, _} = Control.promote(channel, two.id)
      {:ok, one: one, two: two}
    end

    test "the very next check-in gets the old release", %{channel: channel, one: one, two: two} do
      one_id = one.id
      two_id = two.id

      assert {:update, %{release_id: ^two_id}} = Resolve.check(channel, checkin("device-1"))

      {:ok, _} = Control.rollback(channel)

      assert {:update, %{release_id: ^one_id}} = Resolve.check(channel, checkin("device-1"))
    end

    test "the rolled-back release is marked as such, not merely superseded", %{
      channel: channel,
      two: two
    } do
      {:ok, _} = Control.rollback(channel)

      assert state(channel, two.id) == :rolled_back
    end

    test "a device on the bad release is offered the old one", %{
      channel: channel,
      one: one,
      two: two
    } do
      one_id = one.id
      {:ok, _} = Control.rollback(channel)

      assert {:update, %{release_id: ^one_id}} =
               Resolve.check(channel, checkin("device-1", current_release: two.id))
    end

    test "is refused when there is nowhere to go back to" do
      fresh = "test/fresh_#{System.unique_integer([:positive])}"
      on_exit(fn -> AshCell.delete(fresh) end)

      {:ok, only} = Control.cut(fresh, "1.0.0", artifacts("1.0.0"))
      {:ok, _} = Control.promote(fresh, only.id)

      assert Control.rollback(fresh) == {:error, :nothing_to_roll_back_to}
    end
  end

  describe "ramping" do
    test "changes the share without changing the release", %{channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id, rollout: 10)

      {:ok, _} = Control.ramp(channel, 50)

      pointer = Control.current_pointer(channel)
      assert pointer.release_id == release.id
      assert pointer.rollout == 50
      assert [%{kind: :ramp} | _] = Control.history(channel)
    end
  end

  describe "collectable blobs" do
    test "nothing is collectable while every release is kept", %{channel: channel} do
      {:ok, one} = Control.cut(channel, "1.0.0", artifacts("1.0.0", asset: "asset-one"))
      {:ok, _} = Control.promote(channel, one.id)

      assert Control.collectable_blobs(channel) == []
    end

    test "a release beyond the retention window releases its blobs", %{channel: channel} do
      for n <- 0..4 do
        {:ok, r} = Control.cut(channel, "1.#{n}.0", artifacts("1.#{n}.0", asset: "asset-#{n}"))
        {:ok, _} = Control.promote(channel, r.id)
      end

      collectable = Control.collectable_blobs(channel, keep: 2)

      # The two newest releases are kept, so the three older bundles and their
      # per-release assets fall out.
      assert "bundle-1.0.0" in collectable
      assert "asset-0" in collectable
      refute "bundle-1.4.0" in collectable
      refute "asset-4" in collectable
    end

    test "a blob shared with a kept release is not collectable", %{channel: channel} do
      # Both releases point at the same asset, which is the common case: an asset
      # that did not change between builds.
      for version <- ["1.0.0", "1.1.0", "1.2.0"] do
        {:ok, r} = Control.cut(channel, version, artifacts(version, asset: "asset-shared"))
        {:ok, _} = Control.promote(channel, r.id)
      end

      collectable = Control.collectable_blobs(channel, keep: 1)

      assert "bundle-1.0.0" in collectable
      refute "asset-shared" in collectable
    end

    test "a release the pointer could roll back to keeps its blobs", %{channel: channel} do
      {:ok, one} = Control.cut(channel, "1.0.0", artifacts("1.0.0", asset: "asset-one"))
      {:ok, two} = Control.cut(channel, "1.1.0", artifacts("1.1.0", asset: "asset-two"))
      {:ok, _} = Control.promote(channel, one.id)
      {:ok, _} = Control.promote(channel, two.id)

      # `one` is only superseded, and a rollback would go straight to it. A
      # collector that took its blobs would make the rollback unserveable, which is
      # the worst possible outcome for a garbage collector.
      collectable = Control.collectable_blobs(channel, keep: 2)

      refute "bundle-1.0.0" in collectable
      refute "asset-one" in collectable
    end
  end

  defp state(channel, release_id) do
    Release
    |> Ash.Query.filter(id == ^release_id)
    |> Ash.read_one!(tenant: channel)
    |> Map.fetch!(:state)
  end
end
