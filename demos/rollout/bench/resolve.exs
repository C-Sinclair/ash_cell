# What a device check-in costs, cached and uncached.
#
#     mix run bench/resolve.exs
#
# The uncached number is the honest cost of the resolve path: two Ash reads against
# the cell, through the whole framework. The cached number is what a fleet actually
# pays once the manifest has been published for the current epoch.

channel = "bench/prod"
releases = 40
artifacts_per_release = 24
devices = 32
checkins_per_device = 200

AshCell.delete(channel)

IO.puts("seeding #{releases} releases x #{artifacts_per_release} artifacts...")

live =
  Enum.reduce(1..releases, nil, fn n, _acc ->
    artifacts =
      for a <- 1..artifacts_per_release do
        %{
          blob_hash: Base.encode16(:crypto.hash(:sha256, "#{n}-#{a}"), case: :lower),
          kind: Enum.at([:bundle, :asset, :sourcemap], rem(a, 3)),
          platform: Enum.at([:ios, :android], rem(a, 2)),
          arch: Enum.at(["arm64", "x86_64"], rem(div(a, 2), 2)),
          size: 1_000 * a,
          min_runtime: 140 + rem(a, 5),
          max_runtime: nil
        }
      end

    {:ok, release} = Rollout.Control.cut(channel, "1.#{n}.0", artifacts)
    release
  end)

{:ok, _} = Rollout.Control.promote(channel, live.id)

checkin = fn device ->
  %{
    device_id: device,
    platform: :ios,
    arch: "arm64",
    runtime: 142,
    current_release: nil
  }
end

total = devices * checkins_per_device

run = fn fun ->
  fn ->
    1..devices
    |> Task.async_stream(
      fn d ->
        device = "device-#{d}"
        for _ <- 1..checkins_per_device, do: fun.(device)
      end,
      max_concurrency: devices,
      timeout: :infinity
    )
    |> Stream.run()
  end
end

measure = fn label, fun ->
  fun.()

  micros =
    1..5
    |> Enum.map(fn _ -> :timer.tc(fun) |> elem(0) end)
    |> Enum.sort()
    |> Enum.at(2)

  IO.puts(
    String.pad_trailing(label, 34) <>
      String.pad_leading("#{Float.round(micros / total, 2)} µs", 12) <>
      String.pad_leading("#{round(total / (micros / 1_000_000))} resolves/s", 22)
  )
end

IO.puts("""

#{devices} concurrent devices x #{checkins_per_device} check-ins (#{total} resolves), median of 5
""")

# Uncached: rebuild the projection from the cell every time, which is what a resolve
# costs without the cache in front of it.
measure.(
  "uncached (two Ash reads)",
  run.(fn device ->
    manifest = Rollout.Resolve.build(channel)

    Rollout.Resolve.eligible?(device, manifest.release_id, manifest.rollout)
  end)
)

measure.("cached (persistent_term)", run.(fn device -> Rollout.Resolve.check(channel, checkin.(device)) end))

IO.puts("""

A promotion invalidates the manifest, so the first resolve after one pays the
uncached cost and every resolve until the next promotion pays the cached cost.
""")

AshCell.delete(channel)
