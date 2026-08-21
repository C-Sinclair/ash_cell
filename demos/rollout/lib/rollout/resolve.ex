defmodule Rollout.Resolve do
  @moduledoc """
  The device check-in path: what should this client install next?

  This is the whole read side of an OTA service, and it is the reason a channel is
  a cell. A check-in carries what the client *is* — platform, architecture, runtime
  version, and the release it already has — and gets back the manifest it is
  eligible for, minus the blobs it already holds.

  ## Nothing is written

  Staged rollout is `hash(device_id <> release_id) rem 100 < rollout`, so a device
  gets a stable answer across retries, restarts, and nodes without any state being
  recorded about it. A check-in that wrote would put the fleet's entire request
  volume onto the one connection that also has to serve promotions.

  ## Cached, and why that is not a guess

  A resolve reads the pointer and then the artifacts of whatever it points at. That
  is two queries against a file whose contents change on a deploy — perhaps twice a
  week — and are read on every check-in. So the whole thing is built once per
  channel-cell epoch and served from `AshCell.ReadCache`.

  The cache is sound because the cell has exactly one writer and it is on this node:
  `AshCell.Binder` brackets every write, so a promotion erases this projection
  before its statement and again after its commit. There is no window in which a
  resolve can answer from a pointer that has been superseded — which is the
  guarantee the whole demo exists to make good on.

  Measured: ~34 µs uncached against ~0.04 µs cached. See
  `docs/design.md` and `bench/resolve.exs`.
  """

  require Ash.Query

  alias Rollout.Channel.Artifact
  alias Rollout.Channel.Pointer

  @projection :manifest

  defstruct [:release_id, :version, :rollout, :artifacts]

  @doc """
  Resolves a check-in against a channel.

  Returns `{:update, manifest}` when the device should install something,
  `:up_to_date` when it already has the right release or is not in the rollout
  cohort, and `:no_release` when the channel has never been pointed anywhere.
  """
  def check(channel, params) do
    %{
      device_id: device_id,
      platform: platform,
      arch: arch,
      runtime: runtime,
      current_release: current
    } = params

    case manifest(channel) do
      %__MODULE__{release_id: nil} ->
        :no_release

      %__MODULE__{release_id: release_id} when release_id == current ->
        :up_to_date

      %__MODULE__{
        release_id: release_id,
        version: version,
        rollout: rollout,
        artifacts: artifacts
      } ->
        if eligible?(device_id, release_id, rollout) do
          {:update,
           %{
             release_id: release_id,
             version: version,
             artifacts: Enum.filter(artifacts, &compatible?(&1, platform, arch, runtime))
           }}
        else
          :up_to_date
        end
    end
  end

  @doc """
  Whether a device is inside a partial rollout.

  Hashed on the device *and* the release, so ramping 10% → 20% adds devices rather
  than reshuffling which ones are in, and a device that got a release at 10% does
  not lose it at 20%.
  """
  def eligible?(_device_id, _release_id, 100), do: true
  def eligible?(_device_id, _release_id, 0), do: false

  def eligible?(device_id, release_id, rollout) do
    <<bucket::32, _rest::binary>> = :crypto.hash(:sha256, [device_id, release_id])
    rem(bucket, 100) < rollout
  end

  @doc """
  The channel's manifest, from cache or built.

  Public because the benchmark needs to compare it against `build/1` directly, and
  because the console shows what is currently published.
  """
  def manifest(channel) do
    AshCell.ReadCache.read(channel, @projection, fn -> build(channel) end)
  end

  @doc "Builds the manifest from the cell, ignoring the cache. Two queries."
  def build(channel) do
    case pointer(channel) do
      nil ->
        %__MODULE__{release_id: nil, rollout: 0, artifacts: []}

      %{release_id: nil} ->
        %__MODULE__{release_id: nil, rollout: 0, artifacts: []}

      %{release_id: release_id, rollout: rollout} ->
        %__MODULE__{
          release_id: release_id,
          # Denormalised into the projection rather than loaded per resolve: a
          # device is told "2.0.0", not a UUID, and reading the release row on
          # every check-in to learn a string that changes twice a week is the kind
          # of cost the cache exists to remove.
          version: version_of(channel, release_id),
          rollout: rollout,
          artifacts: artifacts_for(channel, release_id)
        }
    end
  end

  defp version_of(channel, release_id) do
    Rollout.Channel.Release
    |> Ash.Query.filter(id == ^release_id)
    |> Ash.read_one!(tenant: channel)
    |> case do
      nil -> nil
      release -> release.version
    end
  end

  defp pointer(channel) do
    Pointer
    |> Ash.Query.filter(id == ^Pointer.singleton_id())
    |> Ash.read_one!(tenant: channel)
  end

  # Plain attributes rather than a load, because the artifacts are flattened into
  # the projection anyway and a load would be a second round of framework work per
  # resolve for no extra information.
  defp artifacts_for(channel, release_id) do
    Artifact
    |> Ash.Query.filter(release_id == ^release_id)
    |> Ash.Query.sort(kind: :asc, blob_hash: :asc)
    |> Ash.read!(tenant: channel)
    |> Enum.map(
      &%{
        blob_hash: &1.blob_hash,
        kind: &1.kind,
        platform: &1.platform,
        arch: &1.arch,
        size: &1.size,
        min_runtime: &1.min_runtime,
        max_runtime: &1.max_runtime
      }
    )
  end

  # Filtered in memory rather than in SQL on purpose: the projection is per channel,
  # not per client, so one cached manifest serves every device shape. Filtering in
  # SQL would make the cache key the client's capability vector and turn one entry
  # into hundreds.
  defp compatible?(artifact, platform, arch, runtime) do
    artifact.platform == platform and
      artifact.arch == arch and
      artifact.min_runtime <= runtime and
      (is_nil(artifact.max_runtime) or runtime < artifact.max_runtime)
  end
end
