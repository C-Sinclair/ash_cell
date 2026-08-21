defmodule Rollout.ResolveTest do
  @moduledoc """
  The read path: what a device is told, and what it is not told.
  """
  use Rollout.ChannelCase, async: false

  test "a channel that has never been pointed anywhere offers nothing", %{channel: channel} do
    assert Resolve.check(channel, checkin("device-1")) == :no_release
  end

  test "a device with nothing installed is offered the live release", %{channel: channel} do
    {:ok, release} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
    {:ok, _} = Control.promote(channel, release.id)

    assert {:update, manifest} = Resolve.check(channel, checkin("device-1"))
    assert manifest.release_id == release.id
    assert Enum.map(manifest.artifacts, & &1.blob_hash) == ["asset-shared", "bundle-1.0.0"]
  end

  test "a device already on the live release is told nothing", %{channel: channel} do
    {:ok, release} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
    {:ok, _} = Control.promote(channel, release.id)

    assert Resolve.check(channel, checkin("device-1", current_release: release.id)) ==
             :up_to_date
  end

  describe "compatibility" do
    setup %{channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", artifacts("1.0.0", min_runtime: 142))
      {:ok, _} = Control.promote(channel, release.id)
      {:ok, release: release}
    end

    test "an artifact below the client's runtime floor is withheld", %{channel: channel} do
      assert {:update, manifest} = Resolve.check(channel, checkin("d", runtime: 141))

      # The bundle needs 142; the asset needs 140. A client on 141 gets the asset
      # only, which is the honest answer -- and the reason a real fleet also needs
      # a "no compatible bundle" signal, which this demo does not model.
      assert Enum.map(manifest.artifacts, & &1.blob_hash) == ["asset-shared"]
    end

    test "another platform gets nothing", %{channel: channel} do
      assert {:update, manifest} = Resolve.check(channel, checkin("d", platform: :android))
      assert manifest.artifacts == []
    end

    test "another architecture gets nothing", %{channel: channel} do
      assert {:update, manifest} = Resolve.check(channel, checkin("d", arch: "x86_64"))
      assert manifest.artifacts == []
    end

    test "a runtime above an artifact's ceiling is withheld", %{channel: channel} do
      {:ok, capped} =
        Control.cut(channel, "1.1.0", artifacts("1.1.0", min_runtime: 140, max_runtime: 145))

      {:ok, _} = Control.promote(channel, capped.id)

      # Only the bundle is capped; the shared asset has no ceiling, so a client past
      # the cap keeps the asset and loses the bundle.
      assert {:update, %{artifacts: [%{kind: :asset}]}} =
               Resolve.check(channel, checkin("d", runtime: 150))

      assert {:update, %{artifacts: [_, _]}} = Resolve.check(channel, checkin("d", runtime: 144))
    end
  end

  describe "staged rollout" do
    test "0 percent reaches nobody and 100 reaches everybody" do
      devices = for n <- 1..200, do: "device-#{n}"
      release = "release-abc"

      assert Enum.count(devices, &Resolve.eligible?(&1, release, 0)) == 0
      assert Enum.count(devices, &Resolve.eligible?(&1, release, 100)) == 200
    end

    test "a partial rollout reaches roughly that share" do
      devices = for n <- 1..2_000, do: "device-#{n}"
      share = Enum.count(devices, &Resolve.eligible?(&1, "release-abc", 10))

      # A hash, not a counter, so this is a distribution rather than a quota.
      assert_in_delta share / 2_000, 0.10, 0.03
    end

    test "ramping up only adds devices" do
      devices = for n <- 1..2_000, do: "device-#{n}"
      at_10 = Enum.filter(devices, &Resolve.eligible?(&1, "release-abc", 10))
      at_20 = Enum.filter(devices, &Resolve.eligible?(&1, "release-abc", 20))

      # The property that matters operationally: a device that received a release
      # at 10% must not lose it at 20%.
      assert Enum.all?(at_10, &(&1 in at_20))
      assert length(at_20) > length(at_10)
    end

    test "a device outside the cohort is told it is up to date", %{channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id, rollout: 10)

      excluded =
        Enum.find(1..500, fn n -> not Resolve.eligible?("device-#{n}", release.id, 10) end)

      assert Resolve.check(channel, checkin("device-#{excluded}")) == :up_to_date
    end

    test "the same device gets the same answer every time", %{channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id, rollout: 37)

      answers =
        for _ <- 1..20, do: Resolve.check(channel, checkin("device-steady")) != :up_to_date

      assert Enum.uniq(answers) |> length() == 1
    end
  end
end
