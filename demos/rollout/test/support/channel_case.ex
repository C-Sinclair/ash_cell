defmodule Rollout.ChannelCase do
  @moduledoc "A fresh channel cell per test, with nothing shared between them."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Rollout.ChannelCase

      alias Rollout.Control
      alias Rollout.Resolve
    end
  end

  # The application already runs one cell fleet, so a test does not start another:
  # it takes a channel name no other test uses, which is the same isolation a real
  # channel has. Cells are files, so cleanup is deleting them.
  setup do
    channel = "test/prod_#{System.unique_integer([:positive])}"

    on_exit(fn -> AshCell.delete(channel) end)

    {:ok, channel: channel}
  end

  @doc "An artifact set for one release: an iOS arm64 bundle plus a shared asset."
  def artifacts(tag, opts \\ []) do
    [
      %{
        blob_hash: "bundle-#{tag}",
        kind: :bundle,
        platform: :ios,
        arch: "arm64",
        size: 2_400_000,
        min_runtime: Keyword.get(opts, :min_runtime, 140),
        max_runtime: Keyword.get(opts, :max_runtime)
      },
      %{
        blob_hash: Keyword.get(opts, :asset, "asset-shared"),
        kind: :asset,
        platform: :ios,
        arch: "arm64",
        size: 90_000,
        min_runtime: 140,
        max_runtime: nil
      }
    ]
  end

  def checkin(device_id, opts \\ []) do
    %{
      device_id: device_id,
      platform: Keyword.get(opts, :platform, :ios),
      arch: Keyword.get(opts, :arch, "arm64"),
      runtime: Keyword.get(opts, :runtime, 142),
      current_release: Keyword.get(opts, :current_release)
    }
  end
end
