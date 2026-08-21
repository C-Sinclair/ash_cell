defmodule Rollout.Seed do
  @moduledoc "Puts three channels into a state worth looking at."

  alias Rollout.Control

  def run do
    for channel <- Rollout.Cells.channels() do
      AshCell.delete(channel)
      seed(channel)
    end

    :ok
  end

  defp seed(channel) do
    releases =
      for version <- ~w[1.0.0 1.1.0 1.2.0] do
        {:ok, release} = Control.cut(channel, version, artifacts(version), notes: notes(version))
        release
      end

    # Every channel is on a different rung, which is what a real fleet looks like
    # and what makes the console worth opening.
    case channel do
      "myapp/prod" ->
        {:ok, _} = Control.promote(channel, Enum.at(releases, 0).id, reason: "shipped")
        {:ok, _} = Control.promote(channel, Enum.at(releases, 1).id, reason: "shipped")

      "myapp/beta" ->
        {:ok, _} = Control.promote(channel, Enum.at(releases, 1).id, reason: "shipped")

        {:ok, _} =
          Control.promote(channel, Enum.at(releases, 2).id, rollout: 25, reason: "ramping")

      _ ->
        {:ok, _} = Control.promote(channel, Enum.at(releases, 2).id, reason: "canary")
    end
  end

  defp notes("1.0.0"), do: "first release"
  defp notes("1.1.0"), do: "offline sync"
  defp notes(_), do: "new onboarding"

  defp artifacts(version) do
    for platform <- [:ios, :android], arch <- arches(platform) do
      %{
        blob_hash: hash(version, platform, arch),
        kind: :bundle,
        platform: platform,
        arch: arch,
        size: 2_000_000 + :erlang.phash2({version, arch}, 500_000),
        min_runtime: 140,
        max_runtime: nil
      }
    end ++
      [
        %{
          blob_hash: hash("assets", version, :shared),
          kind: :asset,
          platform: :ios,
          arch: "arm64",
          size: 480_000,
          min_runtime: 140,
          max_runtime: nil
        }
      ]
  end

  defp arches(:ios), do: ["arm64"]
  defp arches(:android), do: ["arm64", "x86_64"]

  defp hash(a, b, c) do
    :crypto.hash(:sha256, "#{a}-#{b}-#{c}") |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
