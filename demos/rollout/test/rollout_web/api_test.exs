defmodule RolloutWeb.ApiTest do
  @moduledoc """
  The HTTP surface, driven the way the README's curl session drives it.

  `Rollout.ConsistencyTest` proves the rollback guarantee against the resolve path
  directly; this proves the same loop survives being wrapped in a controller —
  including the parts a controller can quietly get wrong, like a channel name with
  a slash in it and a runtime arriving as a version string.
  """
  use RolloutWeb.ConnCase, async: false

  alias Rollout.Control

  setup do
    channel = "test/api_#{System.unique_integer([:positive])}"
    on_exit(fn -> AshCell.delete(channel) end)
    {:ok, channel: channel}
  end

  defp artifacts(tag) do
    [
      %{
        "blob_hash" => "bundle-#{tag}",
        "kind" => "bundle",
        "platform" => "ios",
        "arch" => "arm64",
        "size" => 2_400_000,
        "min_runtime" => 140
      }
    ]
  end

  defp check(conn, channel, opts \\ []) do
    conn
    |> post(~p"/v1/check", %{
      "channel" => channel,
      "device_id" => Keyword.get(opts, :device_id, "phone-1"),
      "platform" => "ios",
      "arch" => "arm64",
      "runtime" => Keyword.get(opts, :runtime, 142),
      "current_release" => Keyword.get(opts, :current_release)
    })
    |> json_response(200)
  end

  describe "POST /v1/check" do
    test "a channel with no release says so", %{conn: conn, channel: channel} do
      assert %{"status" => "no_release"} = check(conn, channel)
    end

    test "returns the manifest for the live release", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id)

      assert %{"status" => "update", "release_id" => id, "artifacts" => [artifact]} =
               check(conn, channel)

      assert id == release.id
      assert artifact["blob_hash"] == "bundle-1.0.0"
      assert artifact["url"] == "/blobs/bundle-1.0.0"
    end

    test "accepts a runtime as a version string", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0", min_runtime: 142))
      {:ok, _} = Control.promote(channel, release.id)

      assert %{"artifacts" => [_]} = check(conn, channel, runtime: "1.42")
      assert %{"artifacts" => []} = check(conn, channel, runtime: "1.41")
    end

    test "the response names the version, not only the release id", %{
      conn: conn,
      channel: channel
    } do
      {:ok, release} = Control.cut(channel, "3.1.4", cut_artifacts("3.1.4"))
      {:ok, _} = Control.promote(channel, release.id)

      # A device is told "3.1.4". Denormalised into the cached projection so that
      # learning it does not cost a read per check-in.
      assert %{"version" => "3.1.4"} = check(conn, channel)
    end

    test "a device already current is told so", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id)

      assert %{"status" => "up_to_date"} = check(conn, channel, current_release: release.id)
    end

    test "a missing device id is a 422, not a guess", %{conn: conn, channel: channel} do
      assert %{"error" => message} =
               conn
               |> post(~p"/v1/check", %{"channel" => channel, "runtime" => 142})
               |> json_response(422)

      assert message =~ "device_id"
    end
  end

  describe "POST /v1/check/batch" do
    test "resolves every check-in in the batch and reports the cost", %{
      conn: conn,
      channel: channel
    } do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id)

      assert %{"count" => 500, "versions" => %{"1.0.0" => 500}, "elapsed_us" => elapsed} =
               conn
               |> post(~p"/v1/check/batch", %{
                 "channel" => channel,
                 "count" => 500,
                 "runtime" => 142
               })
               |> json_response(200)

      assert elapsed > 0
    end

    test "a staged rollout shows up as a mix, not a guess", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id, rollout: 25)

      assert %{"versions" => versions, "count" => 1_000} =
               conn
               |> post(~p"/v1/check/batch", %{
                 "channel" => channel,
                 "count" => 1_000,
                 "runtime" => 142
               })
               |> json_response(200)

      # Hashed per device, so this is a distribution rather than a quota.
      assert_in_delta versions["1.0.0"] / 1_000, 0.25, 0.05
      assert versions["1.0.0"] + versions["up_to_date"] == 1_000
    end

    test "the batch size is capped", %{conn: conn, channel: channel} do
      assert %{"count" => 2_000} =
               conn
               |> post(~p"/v1/check/batch", %{
                 "channel" => channel,
                 "count" => 500_000,
                 "runtime" => 142
               })
               |> json_response(200)
    end

    test "offset keeps device ids distinct across batches", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id, rollout: 50)

      first =
        conn
        |> post(~p"/v1/check/batch", %{"channel" => channel, "count" => 400, "runtime" => 142})
        |> json_response(200)

      second =
        conn
        |> post(~p"/v1/check/batch", %{
          "channel" => channel,
          "count" => 400,
          "offset" => 400,
          "runtime" => 142
        })
        |> json_response(200)

      # Different devices, so the split differs -- an identical split would mean the
      # offset was ignored and the same 400 phones were asked twice.
      refute first["versions"] == second["versions"]
    end
  end

  describe "the operator loop" do
    test "cut, promote, check in, roll back, check in", %{conn: conn, channel: channel} do
      # Cut. Inert until promoted, which the next assertion is the whole point of.
      assert %{"release_id" => one} =
               conn
               |> post(~p"/v1/releases/#{channel}", %{
                 "version" => "1.0.0",
                 "artifacts" => artifacts("1.0.0")
               })
               |> json_response(201)

      assert %{"status" => "no_release"} = check(conn, channel)

      assert %{"release_id" => ^one} =
               conn
               |> post(~p"/v1/promote/#{channel}", %{"release_id" => one})
               |> json_response(200)

      assert %{"release_id" => ^one} = check(conn, channel)

      assert %{"release_id" => two} =
               conn
               |> post(~p"/v1/releases/#{channel}", %{
                 "version" => "2.0.0",
                 "artifacts" => artifacts("2.0.0")
               })
               |> json_response(201)

      conn |> post(~p"/v1/promote/#{channel}", %{"release_id" => two}) |> json_response(200)
      assert %{"release_id" => ^two} = check(conn, channel)

      # And back. The next check-in, over HTTP, gets the old release.
      assert %{"release_id" => ^one, "history" => [latest | _]} =
               conn
               |> post(~p"/v1/rollback/#{channel}", %{"reason" => "crash loop"})
               |> json_response(200)

      assert latest["kind"] == "rollback"
      assert latest["reason"] == "crash loop"

      assert %{"release_id" => ^one} = check(conn, channel)
    end

    test "a write leaves the cache cold and a read warms it", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))

      assert %{"cached" => false} =
               conn
               |> post(~p"/v1/promote/#{channel}", %{"release_id" => release.id})
               |> json_response(200)

      check(conn, channel)

      assert %{"cached" => true} =
               conn |> get(~p"/v1/channels/#{channel}") |> json_response(200)
    end

    test "ramping changes the share, not the release", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id)

      assert %{"rollout" => 25, "release_id" => id} =
               conn
               |> post(~p"/v1/ramp/#{channel}", %{"rollout" => 25})
               |> json_response(200)

      assert id == release.id
    end

    test "upgrade cuts the next patch version and promotes it", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.4.1", cut_artifacts("1.4.1"))
      {:ok, _} = Control.promote(channel, release.id)

      assert %{"version" => "1.4.2"} =
               conn |> post(~p"/v1/upgrade/#{channel}") |> json_response(200)

      assert %{"version" => "1.4.2"} = check(conn, channel)
    end

    test "upgrade then rollback returns the previous version", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.4.1", cut_artifacts("1.4.1"))
      {:ok, _} = Control.promote(channel, release.id)

      conn |> post(~p"/v1/upgrade/#{channel}") |> json_response(200)
      assert %{"version" => "1.4.2"} = check(conn, channel)

      assert %{"version" => "1.4.1"} =
               conn |> post(~p"/v1/rollback/#{channel}") |> json_response(200)

      assert %{"version" => "1.4.1"} = check(conn, channel)
    end

    test "describing a channel reports the cache as it arrived, not as it left", %{
      conn: conn,
      channel: channel
    } do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id)

      # Describing resolves, and resolving populates. Reporting after that would
      # make the field always true and therefore worthless.
      assert %{"cached" => false} =
               conn |> get(~p"/v1/channels/#{channel}") |> json_response(200)

      assert %{"cached" => true} =
               conn |> get(~p"/v1/channels/#{channel}") |> json_response(200)
    end

    test "a rollback with nowhere to go is a 409", %{conn: conn, channel: channel} do
      {:ok, release} = Control.cut(channel, "1.0.0", cut_artifacts("1.0.0"))
      {:ok, _} = Control.promote(channel, release.id)

      assert %{"error" => _} =
               conn |> post(~p"/v1/rollback/#{channel}") |> json_response(409)
    end

    test "a release with no artifacts is refused", %{conn: conn, channel: channel} do
      assert %{"error" => message} =
               conn
               |> post(~p"/v1/releases/#{channel}", %{"version" => "1.0.0", "artifacts" => []})
               |> json_response(422)

      assert message =~ "artifacts"
    end

    test "a channel name with a slash survives the route", %{conn: conn} do
      channel = "test/nested/deep_#{System.unique_integer([:positive])}"
      on_exit(fn -> AshCell.delete(channel) end)

      assert %{"channel" => ^channel} =
               conn |> get(~p"/v1/channels/#{channel}") |> json_response(200)
    end

    test "collectable blobs are reported", %{conn: conn, channel: channel} do
      for version <- ["1.0.0", "1.1.0", "1.2.0"] do
        {:ok, r} = Control.cut(channel, version, cut_artifacts(version))
        {:ok, _} = Control.promote(channel, r.id)
      end

      assert %{"blobs" => blobs, "keep" => 1} =
               conn |> get(~p"/v1/collectable/#{channel}?keep=1") |> json_response(200)

      assert "bundle-1.0.0" in blobs
      refute "bundle-1.2.0" in blobs
    end
  end

  defp cut_artifacts(tag, opts \\ []) do
    [
      %{
        blob_hash: "bundle-#{tag}",
        kind: :bundle,
        platform: :ios,
        arch: "arm64",
        size: 2_400_000,
        min_runtime: Keyword.get(opts, :min_runtime, 140),
        max_runtime: nil
      }
    ]
  end
end
